//
//  PhotoMetadataReader.swift
//  Snowglobe
//
//  Reads where and when a photo was taken from the metadata inside the image file
//  (EXIF / GPS), plus a small preview. The system photo picker hands over the original
//  file, metadata included, so no photo library permission is needed.
//

import Foundation
import ImageIO

struct PhotoMetadata: Equatable, Sendable {
    /// Where the photo was taken, if the file has a usable GPS position.
    var coordinate: GeoCoordinate?
    /// When the photo was taken, if the file says.
    var date: Date?
}

enum PhotoMetadataReader {
    /// Location and capture date from the image file's metadata.
    static func read(imageData data: Data) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return PhotoMetadata() }

        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return PhotoMetadata(
            coordinate: gps.flatMap(coordinate(fromGPS:)),
            date: captureDate(exif: exif, tiff: tiff, gps: gps)
        )
    }

    /// A downscaled, upright copy of the photo for previews.
    static func thumbnail(imageData data: Data, maxPixelSize: Int = 1200) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // apply the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Location

    private static func coordinate(fromGPS gps: [CFString: Any]) -> GeoCoordinate? {
        guard let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        else { return nil }
        // EXIF stores magnitudes; the hemisphere lives in the "Ref" fields.
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        let coordinate = GeoCoordinate(
            latitude: south ? -abs(latitude) : latitude,
            longitude: west ? -abs(longitude) : longitude
        )
        return coordinate.isValid ? coordinate : nil
    }

    // MARK: - Date

    /// EXIF dates are wall-clock times with no zone ("2024:03:03 14:22:10"). Best answer first:
    /// 1. the EXIF time plus its UTC offset (newer iPhones write one),
    /// 2. the GPS timestamp, which is always UTC,
    /// 3. the EXIF time read in the phone's current time zone.
    private static func captureDate(exif: [CFString: Any]?, tiff: [CFString: Any]?, gps: [CFString: Any]?) -> Date? {
        let wallClock = (exif?[kCGImagePropertyExifDateTimeOriginal]
            ?? exif?[kCGImagePropertyExifDateTimeDigitized]
            ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String
        let offset = (exif?[kCGImagePropertyExifOffsetTimeOriginal]
            ?? exif?[kCGImagePropertyExifOffsetTime]) as? String

        if let wallClock, let offset, let zone = timeZone(fromOffset: offset),
           let date = parseExifDate(wallClock, in: zone) {
            return date
        }
        if let day = gps?[kCGImagePropertyGPSDateStamp] as? String,
           let time = gps?[kCGImagePropertyGPSTimeStamp] as? String,
           let date = parseExifDate("\(day) \(time.prefix(8))", in: .gmt) {
            return date
        }
        return wallClock.flatMap { parseExifDate($0, in: .current) }
    }

    private static func parseExifDate(_ string: String, in zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }

    /// "+01:00" / "-07:00" → a fixed-offset time zone.
    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":")
        guard let hours = parts.first.flatMap({ Int($0) }) else { return nil }
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}
