// Vendored from https://github.com/metasidd/Orb
// MIT License — Copyright (c) 2024 Siddhant Mehta
//
// Modifications for native macOS:
//   - UIColor → SKColor (NSColor on macOS, UIColor on iOS via SpriteKit's typealias)
//   - UIGraphicsImageRenderer + UIBezierPath → NSImage + NSBezierPath drawing
//   - scene.scaleMode = .aspectFit → SKSceneScaleMode.aspectFit (avoids contextual
//     inference failure under Swift 6 strict checking)
//   - #Preview block removed

import AppKit
import SwiftUI
import SpriteKit

class ParticleScene: SKScene {
    let color: SKColor
    let speedRange: ClosedRange<Double>
    let sizeRange: ClosedRange<CGFloat>
    let particleCount: Int
    let opacityRange: ClosedRange<Double>

    init(
        size: CGSize,
        color: SKColor,
        speedRange: ClosedRange<Double>,
        sizeRange: ClosedRange<CGFloat>,
        particleCount: Int,
        opacityRange: ClosedRange<Double>
    ) {
        self.color = color
        self.speedRange = speedRange
        self.sizeRange = sizeRange
        self.particleCount = particleCount
        self.opacityRange = opacityRange
        super.init(size: size)

        backgroundColor = .clear
        setupParticleEmitter()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupParticleEmitter() {
        let emitter = SKEmitterNode()

        emitter.particleTexture = createParticleTexture()

        emitter.particleColorSequence = nil
        emitter.particleColor = color
        emitter.particleColorBlendFactor = 1.0

        emitter.particleSpeed = CGFloat(speedRange.lowerBound)
        emitter.particleSpeedRange = CGFloat(speedRange.upperBound - speedRange.lowerBound)
        emitter.particleScale = sizeRange.lowerBound
        emitter.particleScaleRange = sizeRange.upperBound - sizeRange.lowerBound

        emitter.particleAlpha = 0
        emitter.particleAlphaSpeed = CGFloat(opacityRange.upperBound) / 0.5
        emitter.particleAlphaRange = CGFloat(opacityRange.upperBound - opacityRange.lowerBound)

        let alphaSequence = SKKeyframeSequence(keyframeValues: [
            0,
            Double.random(in: opacityRange),
            Double.random(in: opacityRange),
            Double.random(in: opacityRange)
        ], times: [0, 0.2, 0.8, 1.0])
        emitter.particleAlphaSequence = alphaSequence

        let scaleSequence = SKKeyframeSequence(keyframeValues: [
            sizeRange.lowerBound * 0.7,
            sizeRange.upperBound * 0.9,
            sizeRange.upperBound,
            sizeRange.lowerBound * 0.8
        ], times: [0, 0.4, 0.7, 1.0])
        emitter.particleScaleSequence = scaleSequence

        emitter.particleBlendMode = .add

        emitter.position = CGPoint(x: size.width / 2, y: size.height / 2)
        emitter.particlePositionRange = CGVector(dx: size.width, dy: size.height)

        emitter.particleBirthRate = CGFloat(particleCount) / 2.0
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 2.0
        emitter.particleLifetimeRange = 1.0

        emitter.emissionAngle = CGFloat.pi / 2
        emitter.emissionAngleRange = CGFloat.pi / 6

        emitter.xAcceleration = 0
        emitter.yAcceleration = 20

        addChild(emitter)
    }

    private func createParticleTexture() -> SKTexture {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return SKTexture(image: image)
    }
}

struct ParticlesView: View {
    let color: Color
    let speedRange: ClosedRange<Double>
    let sizeRange: ClosedRange<CGFloat>
    let particleCount: Int
    let opacityRange: ClosedRange<Double>

    var scene: SKScene {
        let scene = ParticleScene(
            size: CGSize(width: 300, height: 300),
            color: SKColor(color),
            speedRange: speedRange,
            sizeRange: sizeRange,
            particleCount: particleCount,
            opacityRange: opacityRange
        )
        scene.scaleMode = SKSceneScaleMode.aspectFit
        return scene
    }

    var body: some View {
        GeometryReader { geometry in
            SpriteView(scene: scene, options: [.allowsTransparency])
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea()
        }
    }
}
