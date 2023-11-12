//
//  PreviewView.swift
//  iOSCameraApp
//
//  Created by Jonathan Paul on 11/12/23.
//

import UIKit
import AVFoundation


// To show the user what the camera sees we use an AVCaptureVideoPreviewLayer. It, however, is not a view; it is a CALayer which you can put on a view as it's
// sublayer. This class also facilitates session management

// Why is AVCaptureVideoPreviewLayer a CLLayer rather than UIView?
// This is probably so that we can build custom views on top of the layer, CALayer is more efficient with animation so sepertaing the concern of rendering
// video frames from the view itself could have efficiency benefits.
class PreviewView: UIView {

    // Override from storing CALayer to being an AVCaptureVideoPreviewLayer which is a subclass of CALayer
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    // We will access this property to get the layer rather than accessing the layer and casting it to AVCaptureVideoPreviewLayer repretatively
    // Becasue we overrode the layerClass as AVCaptureVideoPreviewLayer we can expect to ALWAYS be able to cast the layer to AVCaptureVideoPreviewLayer
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check PreviewView.layerClass implementation.")
        }
        return layer
    }

    // Create a way to get the session from the preview layer, conveniently, from the instance of PreviewView directly
    // It also allows us to set the value of the session on the videoPreviewLayer through the instance of PreviewView
    var session: AVCaptureSession? {
        get {
            return videoPreviewLayer.session
        }
        set {
            videoPreviewLayer.session = newValue
        }
    }
}
