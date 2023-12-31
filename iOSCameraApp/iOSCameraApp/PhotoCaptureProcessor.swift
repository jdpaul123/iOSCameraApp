//
//  PhotoCaptureProcessor.swift
//  iOSCameraApp
//
//  Created by Jonathan Paul on 11/12/23.
//


// The app's photo capture delegate object
import AVFoundation
import Photos

class PhotoCaptureProcessor: NSObject {
    private(set) var requestedPhotoSettings: AVCapturePhotoSettings

    private let willCapturePhotoAnimation: () -> Void

    private let livePhotoCaptureHandler: (Bool) -> Void

    lazy var context = CIContext()

    private let completionHandler: (PhotoCaptureProcessor) -> Void

    private var photoData: Data?

    private var livePhotoCompanionMovieURL: URL?

    // Save the location of captured photos.
    var location: CLLocation?

    // TODO: Do these need @escaping if they are set equal to the properties on the class? Won't they continue existing if they are set equal to a property on the class?
    init(with requestedPhotoSettings: AVCapturePhotoSettings,
         willCapturePhotoAnimation: @escaping () -> Void,
         livePhotoCaptureHandler: @escaping (Bool) -> Void,
         completionHandler: @escaping (PhotoCaptureProcessor) -> Void) {
        self.requestedPhotoSettings = requestedPhotoSettings
        self.willCapturePhotoAnimation = willCapturePhotoAnimation
        self.livePhotoCaptureHandler = livePhotoCaptureHandler
        self.completionHandler = completionHandler
    }

    private func didFinish() {
        if let livePhotoCompanionMoviePath = livePhotoCompanionMovieURL?.path {
            if FileManager.default.fileExists(atPath: livePhotoCompanionMoviePath) {
                do {
                    try FileManager.default.removeItem(atPath: livePhotoCompanionMoviePath)
                } catch {
                    print("Could not remove file at url: \(livePhotoCompanionMoviePath)")
                }
            }
        }

        completionHandler(self)
    }
}


/// This extension adopts all of the AVCapturePhotoCaptureDelegate protocol
/// methods.
extension PhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {

    /// - Tag: WillBeginCapture
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if resolvedSettings.livePhotoMovieDimensions.width > 0 && resolvedSettings.livePhotoMovieDimensions.height > 0 {
            livePhotoCaptureHandler(true)
        }
    }

    /// - Tag: WillCapturePhoto
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Using the function that is passed in in the initializer. This willCapturePhotoAnimation() function is written in capturePhoto in the ViewController
        willCapturePhotoAnimation()
    }

    /// - Tag: DidFinishProcessingPhoto
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {

        if let error = error {
            print("Error capturing photo: \(error)")
            return
        }

        self.photoData = photo.fileDataRepresentation()
    }

    // This is new with iOS 17, refer to the WWDC key note about it
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?, error: Error?) {
        if let error = error {
            print("Error capturing deferred photo: \(error)")
            return
        }

        self.photoData = deferredPhotoProxy?.fileDataRepresentation()
    }

    /// - Tag: DidFinishRecordingLive
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL, resolvedSettings: AVCaptureResolvedPhotoSettings) {
        livePhotoCaptureHandler(false)
    }

    /// - Tag: DidFinishProcessingLive
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error != nil {
            print("Error processing Live Photo companion movie: \(String(describing: error))")
            return
        }
        livePhotoCompanionMovieURL = outputFileURL
    }

    /// - Tag: DidFinishCapture
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
            didFinish()
            return
        }

        guard photoData != nil else {
            print("No photo data resource")
            didFinish()
            return
        }

        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    options.uniformTypeIdentifier = self.requestedPhotoSettings.processedFileType.map { $0.rawValue }

                    var resourceType = PHAssetResourceType.photo
                    // If we are using iOS17's deferred photo proxy then resource type is photoProxy rather than photo
                    if  ( resolvedSettings.deferredPhotoProxyDimensions.width > 0 ) && ( resolvedSettings.deferredPhotoProxyDimensions.height > 0 ) {
                        resourceType = PHAssetResourceType.photoProxy
                    }
                    // Add the photo to the Photo Library
                    creationRequest.addResource(with: resourceType, data: self.photoData!, options: options)

                    // Specify the location in which the photo was taken.
                    creationRequest.location = self.location

                    // If it was a live photo add the Live Video to the Photo that was just added
                    if let livePhotoCompanionMovieURL = self.livePhotoCompanionMovieURL {
                        let livePhotoCompanionMovieFileOptions = PHAssetResourceCreationOptions()
                        livePhotoCompanionMovieFileOptions.shouldMoveFile = true
                        creationRequest.addResource(with: .pairedVideo,
                                                    fileURL: livePhotoCompanionMovieURL,
                                                    options: livePhotoCompanionMovieFileOptions)
                    }

                }, completionHandler: { _, error in
                    if let error = error {
                        print("Error occurred while saving photo to photo library: \(error)")
                    }

                    self.didFinish()
                }
                )
            } else {
                self.didFinish()
            }
        }
    }
}
