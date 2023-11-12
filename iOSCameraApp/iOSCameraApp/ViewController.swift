//
//  ViewController.swift
//  iOSCameraApp
//
//  Created by Jonathan Paul on 11/12/23.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    // MARK: Properties
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

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        // FIXME: Testing that the previewView is there
        previewView.backgroundColor = .red
    }
}

