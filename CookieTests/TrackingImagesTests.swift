import Testing

@testable import Cookie

struct TrackingImagesTests {
    @Test func removesARemoteImageWhoseDeclaredSizesAreOnePixel() {
        let html = #"<p>Hi</p><img src="https://example.com/p.gif" width="1" height="1" alt=""><p>Bye</p>"#
        #expect(TrackingImages.removingTrackers(from: html) == "<p>Hi</p><p>Bye</p>")
    }

    @Test func readsInlineSizesAndUnquotedAttributes() {
        let html = "<IMG SRC=http://example.com/o.png style='WIDTH: 0px; max-height:1px !important'/>Text"
        #expect(TrackingImages.removingTrackers(from: html) == "Text")
    }

    @Test func removesKnownTrackerAddressesWithoutSizes() {
        let html = "<div><img\nsrc='https://list.example.com/track/open?u=1&amp;id=2'></div>"
        #expect(TrackingImages.removingTrackers(from: html) == "<div></div>")
    }

    @Test func keepsImagesThatAreNotTrackers() {
        let kept = [
            #"<img src="https://example.com/spacer.gif" width="1" height="20">"#,
            #"<img src="https://example.com/logo.png" width="120">"#,
            #"<img src="https://example.com/hero.png" width="100%">"#,
            #"<img src="cid:logo" width="1" height="1">"#,
            #"<img src="data:image/gif;base64,R0lGOD" width="1" height="1">"#,
            #"<img width="1" height="1">"#,
            #"<img src="https://example.com/logo.png" src="https://example.com/track/open">"#,
            #"<image src="https://example.com/track/open">"#,
        ]
        for html in kept {
            #expect(TrackingImages.removingTrackers(from: html) == html)
        }
    }

    @Test func leavesTagsItCannotReadUnchanged() {
        let unterminatedQuote = #"<p>A</p><img src="https://example.com/track/open width=1><p>B</p>"#
        let unterminatedTag = "<p>A</p><img src=https://example.com/track/open width=1"
        #expect(TrackingImages.removingTrackers(from: unterminatedQuote) == unterminatedQuote)
        #expect(TrackingImages.removingTrackers(from: unterminatedTag) == unterminatedTag)
    }

    @Test func keepsTheRestOfTheBodyIntact() {
        let html = #"Café ☕<img alt="a > b" src="https://u.example.com/wf/open?x=1">naïve <img src="x.png">"#
        #expect(TrackingImages.removingTrackers(from: html) == #"Café ☕naïve <img src="x.png">"#)
    }
}
