//
//  SampleGlobes.swift
//  Snowglobe
//
//  Demo globes added on first launch.
//

import Foundation

enum SampleGlobes {
    static var all: [SnowGlobe] {
        [
            SnowGlobe(title: "Times Square", subtitle: "New York, United States",
                      coordinate: GeoCoordinate(latitude: 40.7580, longitude: -73.9855),
                      radiusMeters: 300, style: .satellite, isSample: true),
            SnowGlobe(title: "Piazza San Marco", subtitle: "Venice, Italy",
                      coordinate: GeoCoordinate(latitude: 45.4341, longitude: 12.3388),
                      radiusMeters: 300, style: .winter, isSample: true),
            SnowGlobe(title: "Half Dome", subtitle: "Yosemite, United States",
                      coordinate: GeoCoordinate(latitude: 37.7459, longitude: -119.5332),
                      radiusMeters: 1500, style: .satellite, isSample: true),
            SnowGlobe(title: "Shibuya Crossing", subtitle: "Tokyo, Japan",
                      coordinate: GeoCoordinate(latitude: 35.6595, longitude: 139.7005),
                      radiusMeters: 250, style: .map, isSample: true),
        ]
    }
}
