import SwiftUI

/// Where MeshChat comes from: the libraries and map data it uses, with their licences (MapLibre's and
/// GRDB's ask for their notices to come with the app).
struct AcknowledgementsView: View {
    struct Credit: Identifiable {
        let name: String
        let what: LocalizedStringKey
        let link: URL
        let licence: String?
        var id: String { name }
    }

    static let credits = [
        Credit(name: "MapLibre Native", what: "The map", link: URL(string: "https://maplibre.org")!, licence: """
BSD 2-Clause License

Copyright (c) 2021 MapLibre contributors

Copyright (c) 2018-2021 MapTiler.com

Copyright (c) 2014-2020 Mapbox

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in
  the documentation and/or other materials provided with the
  distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""),
        Credit(name: "GRDB.swift", what: "The database that keeps your history", link: URL(string: "https://github.com/groue/GRDB.swift")!, licence: """
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""),
        Credit(name: "OpenStreetMap", what: "Map data © OpenStreetMap contributors, under the Open Database Licence", link: URL(string: "https://www.openstreetmap.org/copyright")!, licence: nil),
        Credit(name: "OpenFreeMap", what: "Map tiles and styles, based on OpenMapTiles", link: URL(string: "https://openfreemap.org")!, licence: nil),
        Credit(name: "MeshCore", what: "The open mesh MeshChat works with. MeshChat is an independent app, not affiliated with the MeshCore project.", link: URL(string: "https://meshcore.co.uk")!, licence: nil),
    ]

    var body: some View {
        List {
            ForEach(Self.credits) { c in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(.headline)
                        Text(c.what).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Link(destination: c.link) { Label(c.link.host() ?? c.link.absoluteString, systemImage: "safari") }
                    if let l = c.licence {
                        DisclosureGroup("Licence") { Text(l).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }
}
