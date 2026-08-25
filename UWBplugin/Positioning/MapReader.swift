//
//  MapReader.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/21/25.
//

import Foundation

/// A utility class responsible for loading and decoding anchor map data.
/// The map is represented as a dictionary where each key corresponds to an anchor ID
/// and each value is a `Vector3D` object containing its 3D coordinates.
///
/// Both readers return `nil` on failure instead of aborting: this code is reachable
/// from the Unity bridge, where a malformed JSON must produce an error code, never
/// kill the host process.
class MapReader {

    /// Reads and decodes a JSON file containing anchor coordinates from the framework bundle.
    ///
    /// The JSON file must represent a dictionary in the form:
    /// ```json
    /// {
    ///   "anchor_identifier_1": { "x": 1.0, "y": 2.0, "z": 3.0 },
    ///   "anchor__identifier_2": { "x": 4.0, "y": 5.0, "z": 6.0 }
    /// }
    /// ```
    ///
    /// - Parameter fileName: The name of the JSON file to read, including its extension (e.g. `"anchorMap.json"`).
    /// - Returns: A dictionary mapping each anchor's identifier to its 3D coordinates,
    ///   or `nil` if the file is missing or cannot be decoded.
    static func readCoordinates(from fileName: String) -> [String: Vector3D]? {
        let fileComponents = fileName.split(separator: ".")
        guard fileComponents.count == 2 else {
            print("[UWBplugin]: Invalid map filename '\(fileName)', expected 'name.extension'")
            return nil
        }

        let name = String(fileComponents[0])
        let ext = String(fileComponents[1])

        let bundle = Bundle(for: MapReader.self)
        guard let fileURL = bundle.url(forResource: name, withExtension: ext) else {
            print("[UWBplugin]: Map file '\(fileName)' not found in framework bundle")
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("[UWBplugin]: Could not read map file '\(fileName)'")
            return nil
        }
        return decode(data: data)
    }

    /// Decodes a JSON string representing an anchor map into a dictionary of coordinates.
    ///
    /// This method allows dynamic loading of anchor maps received as raw JSON strings,
    /// for example from an API response or a Unity bridge call.
    ///
    /// - Parameter jsonMap: A JSON string containing the anchor coordinate data.
    /// - Returns: A dictionary mapping each anchor's identifier to its `Vector3D`
    ///   coordinates, or `nil` if the JSON is invalid.
    static func readCoordinatesFromString(jsonMap: String) -> [String: Vector3D]? {
        return decode(data: Data(jsonMap.utf8))
    }

    private static func decode(data: Data) -> [String: Vector3D]? {
        do {
            return try JSONDecoder().decode([String: Vector3D].self, from: data)
        } catch {
            print("[UWBplugin]: Failed to decode anchor map JSON: \(error)")
            return nil
        }
    }
}
