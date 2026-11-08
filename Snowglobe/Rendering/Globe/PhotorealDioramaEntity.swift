//
//  PhotorealDioramaEntity.swift
//  Snowglobe
//
//  Turns a built PhotorealDiorama into RealityKit entities: one unlit, textured model per Google
//  tile (the photos already contain real lighting, like Google Earth) plus the earthy cut edge.
//

import RealityKit
import UIKit
import Metal

@MainActor
enum PhotorealDioramaEntity {
    static func make(from diorama: PhotorealDiorama) async throws -> Entity {
        let content = Entity()
        content.name = GlobeEntityFactory.dioramaContentName
        let sampler = MaterialParameters.Texture.Sampler(clampingSampler())

        for tile in diorama.tiles {
            var descriptor = MeshDescriptor(name: "GoogleTile")
            descriptor.positions = MeshBuffers.Positions(tile.positions)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(tile.uvs)
            descriptor.primitives = .triangles(tile.indices)
            let mesh = try await MeshResource(from: [descriptor])

            var material = UnlitMaterial()
            if let image = tile.image,
               let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture, sampler: sampler))
            } else {
                material.color = .init(tint: UIColor(white: 0.8, alpha: 1))
            }
            material.faceCulling = .none // buildings cut by the circle stay solid when seen from the side
            content.addChild(ModelEntity(mesh: mesh, materials: [material]))
        }

        if !diorama.edge.isEmpty {
            var descriptor = MeshDescriptor(name: "CutEdge")
            descriptor.positions = MeshBuffers.Positions(diorama.edge.positions)
            descriptor.normals = MeshBuffers.Normals(diorama.edge.normals)
            descriptor.primitives = .triangles(diorama.edge.indices)
            var material = GlobeMaterials.pbr(UIColor(red: 0.30, green: 0.22, blue: 0.16, alpha: 1), roughness: 1)
            material.faceCulling = .none
            content.addChild(ModelEntity(mesh: try await MeshResource(from: [descriptor]), materials: [material]))
        }
        content.components.set(SnowSurfaceComponent(field: diorama.snowSurface))
        return content
    }

    /// Google's textures are atlases: clamp at the edges so neighbouring patches don't bleed in.
    private static func clampingSampler() -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return descriptor
    }
}
