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

// TODO: Add NSPhotoLibraryUsageDescription key in Info.plist to save photos and videos
class ViewController: UIViewController {

    // MARK: Properties
    // MARK: Session Management Properties
    let locationManager = CLLocationManager()

    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    private var setUpResult: SessionSetupResult = .notAuthorized // TODO: AVCam initializes this to .success
    private let session = AVCaptureSession() // This session accepts input data from capture devices and sends the data revieved to the correct outputs
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

    // MARK: Capturing Photos Properties
    @IBOutlet private weak var cameraCaptureButton: UIButton!

    private let photoOutput = AVCapturePhotoOutput()

    // FIXME: Why did we not make this optional or have a default value rather than force unwrapping it on first access?
    private var photoSettings: AVCapturePhotoSettings!

    private enum LivePhotoMode {
        case on, off
    }
    private var livePhotoMode: LivePhotoMode = .off

    private var photoQualityPrioritizationMode: AVCapturePhotoOutput.QualityPrioritization = .balanced

    // MARK: View Controller Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()

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

    // MARK: Session Management
    // Only call this on the session queue
    func configureSession() {
        // The app will do nothing if it does not have the right permissions. The user has to go to settings to give the acces now
        // TODO: Prompt the user to change settings if they have not authorized video.
        // TODO: Also. notify them if audio permissions are not authorized so they know why their videos from the app have no audio
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

            // TODO: Come back to KVO for the app
//            AVCaptureDevice.self.addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: &systemPreferredCameraContext)

            // Finally, set the sessions input video device
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput

                /* TODO: Create createDeviceRotationCoordinator() to deal with device rotations
                DispatchQueue.main.async {

                }
                 */
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
        self.photoOutput.isResponsiveCaptureEnabled = self.photoOutput.isResponsiveCaptureSupported
        self.photoOutput.isFastCapturePrioritizationEnabled = self.photoOutput.isFastCapturePrioritizationSupported // TODO: Is this a new feature from iOS 17
        self.photoOutput.isAutoDeferredPhotoDeliveryEnabled = self.photoOutput.isAutoDeferredPhotoDeliverySupported // TODO: Is this a new feature from iOS 17

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
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes]
        }
        photoSettings.photoQualityPrioritization = self.photoQualityPrioritizationMode

        return photoSettings
    }
}

