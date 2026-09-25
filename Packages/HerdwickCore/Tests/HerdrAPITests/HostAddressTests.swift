import HerdrAPI
import Testing

struct HostAddressTests {
    @Test(arguments: [
        ("mac.local", HostAddress(host: "mac.local")),
        ("  Tux@10.0.0.5:2222 ", HostAddress(user: "Tux", host: "10.0.0.5", port: 2222)),
        ("ssh://me@[fd7a:115c::1]:22", HostAddress(user: "me", host: "fd7a:115c::1", port: 22)),
        ("fd7a:115c::1", HostAddress(host: "fd7a:115c::1")),
        ("https://Box.Example.com/herdr?x=1", HostAddress(host: "box.example.com")),
        ("a@b@host", HostAddress(user: "a@b", host: "host")),
    ])
    func parses(input: String, expected: HostAddress) {
        #expect(HostAddress.parse(input) == expected)
    }

    @Test(arguments: ["", "   ", "host:0", "host:70000", "host:ssh", "[::1", "[::1]x", "my host", "user@"])
    func rejects(input: String) {
        #expect(HostAddress.parse(input) == nil)
    }
}
