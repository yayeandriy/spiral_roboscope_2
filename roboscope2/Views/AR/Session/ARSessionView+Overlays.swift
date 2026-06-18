//
//  ARSessionView+Overlays.swift
//  roboscope2
//
//  UI overlays used by ARSessionView (progress and loading indicators)
//

import SwiftUI

extension ARSessionView {
    // MARK: - Registration Progress Overlay
    var registrationProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text(registrationProgress)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            
            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.horizontal, 8)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Model Loading Overlay
    var modelLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading reference model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Scan Loading Overlay
    var scanLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading scanned model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
}

extension LaserGuideARSessionView {
    // MARK: - Registration Progress Overlay
    var registrationProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text(registrationProgress)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.horizontal, 8)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Model Loading Overlay
    var modelLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text("Loading reference model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Scan Loading Overlay
    var scanLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text("Loading scanned model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
}
