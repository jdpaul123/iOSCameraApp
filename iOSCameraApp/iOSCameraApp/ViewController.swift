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
    let locationManager = CLLocationManager()

    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    private var setUpResult: SessionSetupResult = .notAuthorized
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

    // Create the PreviewView which is a view that displays the AVCaptureVideoPreviewLayer as it's backing layer.
    @IBOutlet private weak var previewView: PreviewView!
    @IBOutlet private weak var cameraCaptureButton: UIButton!

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

    // Only call this on the session queue
    func configureSession() {
        // The app will do nothing if it does not have the right permissions. The user has to go to settings to give the acces now
        // TODO: Prompt the user to change settings if they have not authorized video.
        // TODO: Also. notify them if audio permissions are not authorized so they know why their videos from the app have no audio
        if setUpResult != .success {
            return
        }
    }
}

