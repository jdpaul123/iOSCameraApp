//
//  ViewController.swift
//  iOSCameraApp
//
//  Created by Jonathan Paul on 11/12/23.
//

import UIKit
import AVFoundation
import CoreLocation

/*
 Steps to set up a camera app:
 - Create an AVSession
 - Create a view that contains a sublayer for previewing the video feed from a layer called AVCapturePreviewVideoLayer
 - Connect the AVSession instance to the AVCapturePreviewVideoLayer instance
 - Add permission for location, video, and audio in plist
 - Get permission for location, video, and audio in the viewDidLoad() method
 - Setup the session if you get the video permission
    - Setup should not block the main thread so do all of the work on a dedicated serial dispatch queue
 */

// TODO: Make the capturePhotoButton and all UI move correctly when the orientation of the device changes
// TODO: Add NSPhotoLibraryUsageDescription key in Info.plist to save photos and videos
class ViewController: UIViewController, AVCapturePhotoOutputReadinessCoordinatorDelegate {

    // MARK: Session Management Properties
    let locationManager = CLLocationManager()

    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    private var setUpResult: SessionSetupResult = .success // We assume success unless there is some kind of failure or permission denial that occurs in ViewDidLoad or ViewWillAppear
    let session = AVCaptureSession() // This session accepts input data from capture devices and sends the data revieved to the correct outputs
    private var isSessionRunning = false
    private let sessionQueue = DispatchQueue(label: "session queue")
    /*
     Steps to use session:
     - Create the session
     - Configure inputs
     - Configure outputs
     - Tell the session to start and then stop capture

     All interaction with the session should happen off of the main queue to avoid dropping frames.
     Create a dedicated serial dispatch queue for the session so that events occur in the right order and do not block the main thread.
     We should also dispatch tasks such as resuming an interrupted session, toggling capture modes, switching cameras, and writing media to a file to
     the session queue so as to not block the main threads priority of keeping a smooth UI/UX running.
     */

    // @objc exposes this property to be able to be used in objective-c. For cross-language interopability
    // dynamic enables dynamic dispatch for the property. In swift most everything uses static dispatch by default.
    // In dynamic dispatch the exact property to be used is determined at runtime
    // TODO: I think that @objc dynamic is necessary for key-value observice (KVO)
    @objc dynamic var videoDeviceInput : AVCaptureDeviceInput!

    // Create the PreviewView which is a view that displays the AVCaptureVideoPreviewLayer as it's backing layer.
    @IBOutlet private weak var previewView: PreviewView!

    // MARK: Labels and Buttons
    @IBOutlet var cameraUnavailableLabel: UILabel!
    @IBOutlet var resumeButton: UIButton!

    // MARK: Capturing Photos Properties
    @IBOutlet private weak var cameraCaptureButton: UIButton!

    private let photoOutput = AVCapturePhotoOutput()

    private var photoOutputReadinessCoordinator: AVCapturePhotoOutputReadinessCoordinator!

    // FIXME: Why did we not make this optional or have a default value rather than force unwrapping it on first access?
    private var photoSettings: AVCapturePhotoSettings!

    private enum LivePhotoMode {
        case on, off
    }
    private var livePhotoMode: LivePhotoMode = .off
    private var inProgressLivePhotoCapturesCount = 0

    private var photoQualityPrioritizationMode: AVCapturePhotoOutput.QualityPrioritization = .balanced

    private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()

    // MARK: Recording Videos Properties
    private var movieFileOutput: AVCaptureMovieFileOutput?

    // TODO: Uncomment this when I impliment video
//    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
//                                                                               mediaType: .video, position: .unspecified)

    // MARK: View Controller Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()

        // TODO: This button never gets enabled, so it must get enabled at some point
        // Disable buttons until everything is setup
        cameraCaptureButton.isEnabled = false

        // Connect the instance of AVCaptureSession called self.session to the previewView's session property. The setter in Preview View then sets this\
        // instance of AVCaptureSession to the session for the AVCaptureVideoPreviewLayer instance called videoPreviewLayer. videoPreviewLayer's setter
        // then sets Preview View's "layer" property to itself cast to the type of AVCaptureVideoPreviewLayer. This works becasue Preview View overrides
        // the UIView "layerClass" property to store AVCaptureVideoPreviewLayer.self.
        previewView.session = session

        // Request the users location to save it in the metadata of each photo/video taken
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        // Get audio and video access. Video is required. Audio is not, but if it is not granted then the videos will have no sound
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break // No need to request access again
        case .notDetermined:
            // The user has not given or denied access. Pause the session queue to stop setting it up until we have access
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] isGranted in // using weak self here becasue this is @escaping.
                // Given that this is a single view app self shouldn't ever deinit, but this [weak self] allows for future feature additions, while mitigating bugs
                guard let self = self else {
                    fatalError("Self no longer exists so app cannot determine camera video authorization status or continue setting up the session")
                }
                if !isGranted {
                    self.setUpResult = .notAuthorized
                }
                self.sessionQueue.resume()
            }
        default:
            // The user has already denied access to video
            // treating cases .restricted and .denied as the same thing
            setUpResult = .notAuthorized
        }

        // Now that we know all of our authorization statuses we can setup the session on the session queue
        // In configureSession we call AVCapture.startRunning() which is especially bad to do on the main thread because it is a blocking call
        // and takes a moment to run
        sessionQueue.async {
            self.configureSession()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        sessionQueue.async {
            switch self.setUpResult {
            case .success:
                // Only setup observers and start the session if setup succeeded.
                self.addObservers()
                // After this code gets run the user will see the AVCaptureVideoPreview layer with a live preivew from the selected camera
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
            case .notAuthorized:
                // If the user is not authorized tell them to go settings and allow video
                DispatchQueue.main.async {
                    let changePrivacySetting = "AVCam doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))

                    self.present(alertController, animated: true, completion: nil)
                }
            case .configurationFailed:
                // If the config fialed then say it failed and dont do anything about it
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))

                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }

    // Only break down the AVCaptureSession instance if it setup. Then stop it from running
    // Restart the sesison every time we reopen the app even if it was already open
    override func viewWillDisappear(_ animated: Bool) {
        sessionQueue.async {
            if self.setUpResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                self.removeObservers()
            }
        }
    }

    // MARK: Session Management
    // Only call this on the session queue
    private func configureSession() {
        // The app will do nothing if it does not have the right permissions. The user has to go to settings to give the acces now
        // TODO: notify them if audio permissions are not authorized so they know why their videos from the app have no audio
        if setUpResult != .success {
            return
        }

        // Makes atomic updates to the session to avoid any changes of the session happening in the wrong order and causing unexpected results
        // end block with session.commitConfiguration()
        session.beginConfiguration()

        // Do not create an AVCaptureMovieFileOutput when setting up the session
        // because Live Photo is not supported when AVCaptureMovieFileOutput is
        // added to the session.

        // Set the quality level or bit rate for the captured media
        session.sessionPreset = .photo

        /*
         Steps to configure the session to be ready to take photos
         Add video input
         Add audio input
         Add photo output
         */

        // Add video input
        do {
            // Handle the situation when the system-preferred camera is nil.
            var defaultVideoDevice: AVCaptureDevice? = AVCaptureDevice.systemPreferredCamera // Apple determines this camera bases on many factors. It can change at any time

            let userDefaults = UserDefaults.standard
            // If there is no saved initial camera and Apple determines there is no preferred camera then create a discovery session to determine it in-app
            if !userDefaults.bool(forKey: "setInitialUserPreferredCamera") || defaultVideoDevice == nil {
                // We would prefer to star the app on the back camera
                // This constant will contain the best possible camera available based on the order of deviceTypes
                let backVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera],
                                                                                       mediaType: .video, position: .back)

                // Lets save this as the default camera for next time the app is opened
                defaultVideoDevice = backVideoDeviceDiscoverySession.devices.first

                AVCaptureDevice.userPreferredCamera = defaultVideoDevice

                userDefaults.set(true, forKey: "setInitialUserPreferredCamera")
            }

            // Default video device could still be nil if we have not found a camera that is available
            guard let videoDevice = defaultVideoDevice else {
                print("Default video device unavailable.")
                setUpResult = .configurationFailed
                session.commitConfiguration()
                return
            }

            // Create our input device that will be connected to the session
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

            // TODO: Come back to this when implimenting switching cameras
//            AVCaptureDevice.self.addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: &systemPreferredCameraContext)

            // Finally, set the sessions input video device
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput

                DispatchQueue.main.async {
                    // You do not need to serialize AVCaptureVideoPreviewLayer's connection with other session manipulation
                    // This is on the main thread because changing orientations affects the UI
                    // This deals with rotation of the AVCaptureVideoPreviewLayer, but does NOT deal with moving the buttons on screen correctly
                    self.createDeviceRotationCoordinator()
                }
            } else {
                print("Couldn't add video device input to the session.")
                setUpResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couln't create video device input: \(error)")
            setUpResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Add an audio input device.
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            // Force unwrap: Assume that we got an audio device whether it is nil or not
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)

            // Add the audio device to the session
            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                print("Could not add audio device input to the session")
            }
        } catch {
            print("Could not create audio device input: \(error)")
        }

        // Add the photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // Set live photo mode on if possible
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
            // Indicates that the output that the reciever must be able to handle up to .quality level quality
            photoOutput.maxPhotoQualityPrioritization = .quality
            // TODO: Not sure why we save this property? I am guessing it has to do with switching between photos and videos
            livePhotoMode = photoOutput.isLivePhotoCaptureEnabled ? .on : .off
            // Set our default preference for photo quality.
            photoQualityPrioritizationMode = .balanced

            // Now configure the output. In configurePhotoOutput() it also calls setUpPhotoSettings()
            self.configurePhotoOutput()

            // AVCapturePhotoOutputReadinessCoordinator is new in iOS 17. It monitors an AVCapturePhotoOutput object's readiness
            // ViewController conforms to AVCapturePhotoOutputReadinessCoordinatorDelege so we can use the methods in that delegate
            // to react to changes in the readiness value to know when to update the UI from a background queue like the session queue.
            let readinessCoordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
            DispatchQueue.main.async {
                self.photoOutputReadinessCoordinator = readinessCoordinator
                readinessCoordinator.delegate = self
            }
        } else {
            print("Could not add photo output to the session")
            setUpResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()
    }

    private func configurePhotoOutput() {
        let supportedMaxPhotoDimensions = self.videoDeviceInput.device.activeFormat.supportedMaxPhotoDimensions
        // TODO: Why do we get the .last item? My guess is that .supportedMaxPhotoDimensions always holds an array of 1 CMVideoDimensions or it's empty otherwise
        let largestDimension = supportedMaxPhotoDimensions.last
        self.photoOutput.maxPhotoDimensions = largestDimension!
        // Set these different options for the photo output if they are supported
        self.photoOutput.isLivePhotoCaptureEnabled = self.photoOutput.isLivePhotoCaptureSupported
        self.photoOutput.maxPhotoQualityPrioritization = .quality
        self.photoOutput.isResponsiveCaptureEnabled = self.photoOutput.isResponsiveCaptureSupported // New for iOS 17: Allows paralellization of photo processing to allow photo capture to happen quicker. Hititng capture button multiple times in quick succession
        self.photoOutput.isFastCapturePrioritizationEnabled = self.photoOutput.isFastCapturePrioritizationSupported // New for iOS 17: allows for quality to go from .quality to .balanced if user is taking a bunch of photos at once
        self.photoOutput.isAutoDeferredPhotoDeliveryEnabled = self.photoOutput.isAutoDeferredPhotoDeliverySupported // New for iOS 15: Allows using Deep Fusion, but defering the photo processing until the user is done taking photos to keep a more responsive UI and higher quality photos.
        // Deferred Photo Delivery uses a proxy photo in the short term and replaces it with the fully processed photo later

        let photoSettings = self.setUpPhotoSettings()
        DispatchQueue.main.async {
            self.photoSettings = photoSettings
        }
    }

    private func setUpPhotoSettings() -> AVCapturePhotoSettings {
        var photoSettings = AVCapturePhotoSettings()

        // Capture HEIF photos when supported
        if self.photoOutput.availablePhotoCodecTypes.contains(AVVideoCodecType.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            // FIXME: This seems to be redundant
            photoSettings = AVCapturePhotoSettings()
        }

        // Set the flash to auto mode
        if self.videoDeviceInput.device.isFlashAvailable {
            photoSettings.flashMode = .auto
        }

        photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions

        // TODO: What does this if statement do?
        if !photoSettings.availablePreviewPhotoPixelFormatTypes.isEmpty {
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
        }

        // Turn on live photo mode if it is set to be on
        if self.livePhotoMode == .on && self.photoOutput.isLivePhotoCaptureSupported { // Live capture mode is not supported in movie mode
            photoSettings.livePhotoMovieFileURL = livePhotoMovieUniqueTemporaryDirectoryFileURL()
        }

        photoSettings.photoQualityPrioritization = self.photoQualityPrioritizationMode


        return photoSettings
    }

    @IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
        sessionQueue.async {
            // The session might fail to start running, for example, if a phone
            // or FaceTime call is still using audio or video. This failure is
            // communicated by the session posting a runtime error notification.
            // To avoid repeatedly failing to start the session, only try to
            // restart the session in the error handler if you aren't trying to
            // resume the session.
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }

    // MARK: Capturing Photos
    @IBAction private func capturePhoto(_ photoButton: UIButton) {
        print("capturePhoto called")
        if self.photoSettings == nil {
            print("No photo settings to capture")
            return
        }

        // Create a unique settings object for the request from our photoSettings
        let photoSettings = AVCapturePhotoSettings(from: self.photoSettings)

        // Provide a unique temporary URL to write the Live Photo Movie to because Live Photo captures can overlap
        if photoSettings.livePhotoMovieFileURL != nil {
            photoSettings.livePhotoMovieFileURL = livePhotoMovieUniqueTemporaryDirectoryFileURL()
        }

        // Start tracking capture readiness on the main thread to synchronously update the shutter button's availability
        self.photoOutputReadinessCoordinator.startTrackingCaptureRequest(using: photoSettings)

        let videoRotationAngle = self.videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelCapture

        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoRotationAngle = videoRotationAngle
            }

            let photoCaptureProcessor = PhotoCaptureProcessor(with: photoSettings) {
                // Will capture photo animation: flash the screen to signal that AVCam took a photo
                DispatchQueue.main.async {
                    self.previewView.videoPreviewLayer.opacity = 0
                    UIView.animate(withDuration: 0.25) {
                        self.previewView.videoPreviewLayer.opacity = 1
                    }
                }
            } livePhotoCaptureHandler: { capturing in
                // multiple Live Photo videos could be capturing at once
                self.sessionQueue.async {
                    if capturing {
                        self.inProgressLivePhotoCapturesCount += 1
                    } else {
                        self.inProgressLivePhotoCapturesCount -= 1
                    }

                    // TODO: Impliment the below by creating the capturingLivePhotoLabel to show the user when the Live Photo video is being taken
                    // Copy the value of self.inProgresLivePhotoCapturesCount now in case the value changes before the async work below occurs
//                    let inProgressLivePhotoCapturesCount = self.inProgressLivePhotoCapturesCount
//                    DispatchQueue.main.async {
//                        if inProgressLivePhotoCapturesCount > 0 {
//                            self.capturingLivePhotoLabel.isHidden = false
//                        } else if inProgressLivePhotoCapturesCount == 0 {
//                            self.capturingLivePhotoLabel.isHidden = true
//                        } else {
//                            print("Error: In progress Live Photo capture count is less than 0.")
//                        }
//                    }
                }
            } completionHandler: { photoCaptureProcessor in
                // When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated
                self.sessionQueue.async {
                    self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = nil
                }
            }

            // Specify the location the photo was taken
            photoCaptureProcessor.location = self.locationManager.location

            // The photoOutput holds a weak reference to the photo capture delegate (aka. PhotoCaptureProcessor) and stores
            // it in an array to maintain a strong reference. The key is the unique id of the current photo settings and the
            // value is our photo capture delegate
            // If we did not create this dictionary and save the photoCaptureProcessor then once we exit this async work block
            // the Reference Counter would go to zero because it is initialized in this current scope. Then the photoCaptureProcessor would be deallocated :(
            // We would then not have a PhotoCaptureDelegate to handle and save the photo.
            // Now we can allow the photoCaptureProcessor to finish it's job and then access it at the end of it's work and deinit it by setting it to nil in the dictionary
            self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
            // Now take the photo connecting the photoSettings we have set up and the photoCaptureProcessor delegate instance that will handle the events during
            // the life cycle of taking an image
            self.photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)

            // Stop tracking the capture request because it's now destined for the photo output.
            self.photoOutputReadinessCoordinator.stopTrackingCaptureRequest(using: photoSettings.uniqueID)
        }
    }

    private func livePhotoMovieUniqueTemporaryDirectoryFileURL() -> URL {
        let livePhotoMovieFileName = UUID().uuidString
        let livePhotoMovieFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((livePhotoMovieFileName as NSString).appendingPathExtension("mov")!)
        let livePhotoMovieURL = NSURL.fileURL(withPath: livePhotoMovieFilePath)
        return livePhotoMovieURL
    }

    @IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
        let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: gestureRecognizer.view))
        focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
    }

    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        sessionQueue.async {
            let device = self.videoDeviceInput.device
            do {
                try device.lockForConfiguration()

                // Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                // Call set(Focus/Exposure)Mode() to apply the new point of interest.
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }

                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }

                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }

    // MARK: Change camera
//    private func changeCamera(_ videoDevice: AVCaptureDevice?, isUserSelection: Bool, completion: (() -> Void)? = nil) {
//        sessionQueue.async {
//            let currentVideoDevice = self.videoDeviceInput.device
//            let newVideoDevice: AVCaptureDevice?
//
//            // if we pass in a video device to switch to make that the new one
//            if let videoDevice = videoDevice {
//                newVideoDevice = videoDevice
//            } else {
//                let currentPosition = currentVideoDevice.position // .front .back. or .unspecified
//
//                let backVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera],
//                                                                                       mediaType: .video, position: .back)
//
//                let frontVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera],
//                                                                                        mediaType: .video, position: .front)
//
//                let externalVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
//                                                                                           mediaType: .video, position: .unspecified)
//
//                switch currentPosition {
//                case .unspecified, .front:
//                    newVideoDevice = backVideoDeviceDiscoverySession.devices.first
//
//                case .back:
//                    // Prioritize an external camera, like a plug in web-cam, over the built in back camera
//                    if let externalCamera = externalVideoDeviceDiscoverySession.devices.first {
//                        newVideoDevice = externalCamera
//                    } else {
//                        newVideoDevice = frontVideoDeviceDiscoverySession.devices.first
//                    }
//                @unknown default:
//                    print("Unknown capture position. Defaulting to back, dual-camera")
//                    newVideoDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
//                }
//            }
//
//            if let videoDevice = newVideoDevice {
//                do {
//                    let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
//
//                    self.session.beginConfiguration()
//
//                    // Remove the existing device input first, because AVCaptureSession doesn't support simultaneous use of the read and front cameras.
//                    self.session.removeInput(self.videoDeviceInput)
//
//                    if self.session.canAddInput(videoDeviceInput) {
//                        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: currentVideoDevice)
//                        NotificationCenter.default.addObserver(self, selector: #selector(self.subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: videoDeviceInput.device)
//
//                        self.session.addInput(videoDeviceInput)
//                        self.videoDeviceInput = videoDeviceInput
//
//                        if isUserSelection {
//                            AVCaptureDevice.userPreferredCamera = videoDevice
//                        }
//
//                        // The DEvice Rotation Coordinator takes in the input device to keep track of so we must create a new coordinator for the new video AVCaptureDeviceInput
//                        DispatchQueue.main.async {
//                            self.createDeviceRotationCoordinator()
//                        }
//                    } else {
//                        // just reset the session back to the way it was if we cannot add the new input device
//                        self.session.addInput(self.videoDeviceInput)
//                    }
//
//                    // Now we deal with if we are switching to recording movies
//                    if let connection = self.movieFileOutput?.connection(with: .video) {
//                        self.session.sessionPreset = .high
//
//                        self.selectedMovieMode10BitDeviceFormat = self.tenBitVariantOfFormat(activeFormat: self.videoDeviceInput.device.activeFormat)
//                    }
//                }
//            }
//        }
//    }

    // MARK: Video Recording Functions
    // TODO: Understand this function
    func tenBitVariationOfFormat(activeFormat: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        let formats = self.videoDeviceInput.device.formats
        let formatIndex = formats.firstIndex(of: activeFormat)!

        let activeDimensions = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
        let activeMaxFrameRate = activeFormat.videoSupportedFrameRateRanges.last?.maxFrameRate
        let activePixelFormat = CMFormatDescriptionGetMediaSubType(activeFormat.formatDescription)

        // AVCaptureDeviceFormats are sorted from smallest to largest in resolution and frame rate. For each resolution and max frame rate there's a cluster of formats that only differ in pixelFormatType.
        // Here, we look for an 'x420' variant of the current activeFormat.
        if activePixelFormat != kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            // Current active format is not a 10-bit HDR format, find its 10-bit HDR variant.
            for index in formatIndex + 1..<formats.count {
                let format = formats[index]
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let maxFrameRate = format.videoSupportedFrameRateRanges.last?.maxFrameRate
                let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)

                // Don't advance beyond the current format cluster
                if activeMaxFrameRate != maxFrameRate || activeDimensions.width != dimensions.width || activeDimensions.height != dimensions.height {
                    break
                }

                if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
                    return format
                }
            }
        } else {
            return activeFormat
        }

        return nil
    }



    // MARK: Readiness Coordinator

    // This function is a delegate function from conforming to AVCapturePhotoOutputReadinessCoordinatorDelegate
    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator, captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        // Enable user interaction fro the shutter button only when the output is ready to capture
        self.cameraCaptureButton.isUserInteractionEnabled = (captureReadiness == .ready) ? true : false

        // Note: You can customize the shutter button's appearance based on `captureReadiness`.
    }

    // MARK: Device Rotation
    // RotationCoordinator monitors the orientation of the device relative to gravity
    private var videoDeviceRotationCoordinator: AVCaptureDevice.RotationCoordinator!
    private var videoRotationAngleForHorizonLevelPreviewObservation: NSKeyValueObservation?

    // Deals with rotating the AVCaptureVideoPreviewLayer when the devices orientation changes
    private func createDeviceRotationCoordinator() {
        videoDeviceRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDeviceInput.device, previewLayer: previewView.videoPreviewLayer)
        // The connection manages the flow of data between the capture device (camera) and the output (preview layer)
        previewView.videoPreviewLayer.connection?.videoRotationAngle = videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelPreview

        // Using KVO, observe any changes to roation and update the previewView's videoPreviewLayer's (type: AVCaptureVideoPreviewLayer) videoRoationAngle
        videoRotationAngleForHorizonLevelPreviewObservation = videoDeviceRotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new, changeHandler: { _, change in
            guard let videoRotationAngleForHorizonLevelPreview = change.newValue else { return }

            self.previewView.videoPreviewLayer.connection?.videoRotationAngle = videoRotationAngleForHorizonLevelPreview
        })
    }

    // MARK: KVO and Notifications

    private var keyValueObservations = [NSKeyValueObservation]()
    /// - Tag: ObserveInterruption
    private func addObservers() {
        let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
            guard let isSessionRunning = change.newValue else { return }
//          TODO: NEED THIS FOR ENABLING A DIFFERENT BUTTON  let isLivePhotoCaptureEnabled = self.photoOutput.isLivePhotoCaptureEnabled

            DispatchQueue.main.async {
                self.cameraCaptureButton.isEnabled = isSessionRunning
            }
        }
        keyValueObservations.append(keyValueObservation)

        // Observe interuptions
        // TODO: I think this is for changing the focus as the camera's focus or exposure changes to focus on the middle of the screen?
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange,
                                               object: videoDeviceInput.device)

        // If there is a runtime error, this is how we deal with it
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)

        // A session can only run when the app is fill screen. It will be
        // interrupted in a multi-app layout, introduced in iOS 9, see also the
        // documentation of AVCaptureSessionInterruptionReason. Add observers to
        // handle these session interruptions and show a preview is paused
        // message. See `AVCaptureSessionWasInterruptedNotification` for other
        // interruption reasons.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
    }

    @objc func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }

    @objc func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }

        print("Capture session runtime error: \(error)")
        // If media services were reset, and the last start succeeded, restart the session
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    // Line below restarts the session
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }

    @objc func sessionWasInterrupted(notification: NSNotification) {
        // In some scenarios you want to enable the user to resume the session.
        // For example, if music playback is initiated from Control Center while
        // using AVCam, then the user can let AVCam resume the session running,
        // which will stop music playback. Note that stopping music playback in
        // Control Center will not automatically resume the session. Also note
        // that it's not always possible to resume, see
        // `resumeInterruptedSession(_:)`.
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
           let reasonIntegerValue = userInfoValue.integerValue,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")

            var showResumeButton = false
            if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
                showResumeButton = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Fade-in a label to inform the user that the camera is
                // unavailable.
                cameraUnavailableLabel.alpha = 0
                cameraUnavailableLabel.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1
                }
            } else if reason == .videoDeviceNotAvailableDueToSystemPressure {
                print("Session stopped running due to shutdown system pressure level.")
            }
            if showResumeButton {
                // Fade-in a button to enable the user to try to resume the
                // session running.
                resumeButton.alpha = 0
                resumeButton.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1
                }
            }
        }
    }

    @objc func sessionInterruptionEnded(notification: NSNotification) {
        print("Capture session interruption ended")

        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            })
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)

        for keyValueObservation in keyValueObservations {
            keyValueObservation.invalidate()
        }
        keyValueObservations.removeAll()
    }

    // TODO: Come back to this when implimenting switching cameras
//    private var systemPreferredCameraContext = 0
//
//    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
//        if context == &systemPreferredCameraContext {
//            guard let systemPreferredCamera = change?[.newKey] as? AVCaptureDevice else { return }
//
//            // Don't switch cameras if movie recording is in progress.
//            if let movieFileOutput = self.movieFileOutput, movieFileOutput.isRecording {
//                return
//            }
//            if self.videoDeviceInput.device == systemPreferredCamera {
//                return
//            }
//
//            self.changeCamera(systemPreferredCamera, isUserSelection: false)
//        } else {
//            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
//        }
//    }
}


// MARK: AVCaptureDevice.DiscoverySession
// TODO: Figure out what this is for. IK it has to do with video
//extension AVCaptureDevice.DiscoverySession {
//    var uniqueDevicePositionsCount: Int {
//
//        var uniqueDevicePositions = [AVCaptureDevice.Position]()
//
//        for device in devices where !uniqueDevicePositions.contains(device.position) {
//            uniqueDevicePositions.append(device.position)
//        }
//
//        return uniqueDevicePositions.count
//    }
//}
