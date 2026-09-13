//
//  CodeSigning.swift
//  Shared
//

import Security

/// Utilities for inspecting the current process's code signature.
enum CodeSigning {
    /// The Team Identifier of the running process, or `nil` if the process is
    /// unsigned or ad-hoc signed.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard
            SecCodeCopySelf([], &code) == errSecSuccess,
            let code
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            return nil
        }

        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &info
            ) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamIdentifier.isEmpty
        else {
            return nil
        }

        return teamIdentifier
    }

    /// Whether the process can satisfy an `isFromSameTeam` XPC requirement.
    static var hasTeamIdentifier: Bool {
        teamIdentifier != nil
    }
}
