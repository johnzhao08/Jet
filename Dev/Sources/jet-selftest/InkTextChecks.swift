import Foundation
import AppKit
import CoreGraphics
import PencilKit
@testable import JetKit

// Outcome checks for typed text on handwritten (.ink) pages: old files still open, text survives a
// save/reopen next to ink and pictures, two devices' edits merge through git, and the AI helper
// is shown the page. Uses `expect`, `failures`, `stroke(y:at:)` and `shell` from main.swift.

private func textDoc(_ strokes: [PKStroke] = [], images: [InkImage] = [], texts: [InkText] = [],
                     paper: PaperStyle = .lined) -> Data {
    InkDocument(paper: paper, drawing: PKDrawing(strokes: strokes).dataRepresentation(),
                images: images, texts: texts).encoded()
}

private func decoded(_ data: Data?) -> InkDocument? { data.flatMap(InkDocument.decode) }

private func textsOf(_ data: Data?) -> [InkText] { decoded(data)?.texts ?? [] }

private func texts(at url: URL) -> [InkText] { textsOf(try? Data(contentsOf: url)) }

func checkInkText(work: URL) {
    let fm = FileManager.default
    let t0 = Date(timeIntervalSinceReferenceDate: 810_000_000)
    let photo = InkImage(id: "p1", path: "Attachments/a.png", frame: CGRect(x: 10, y: 20, width: 300, height: 200))
    let baseStroke = stroke(y: 50, at: t0)

    print("12b. Old notes open, and typed text round-trips beside ink and pictures")
    do {
        // A note written before text existed: no "texts" key at all.
        let drawing = PKDrawing(strokes: [baseStroke]).dataRepresentation().base64EncodedString()
        let legacyInk = Data(#"{"drawing":"\#(drawing)","paper":"grid","version":1}"#.utf8)
        let legacy = InkDocument.decode(legacyInk)
        expect(legacy != nil && legacy?.paper == .grid && legacy?.pkDrawing.strokes.count == 1,
               "a note saved before text existed still opens with its ink")
        expect((legacy?.texts ?? []).isEmpty, "…and has no text")
        // (JSONEncoder escapes "/" in the base64, so compare the JSON, not the spelling.)
        let before = try? JSONSerialization.jsonObject(with: legacyInk) as? NSDictionary
        let after = legacy.flatMap { try? JSONSerialization.jsonObject(with: $0.encoded()) as? NSDictionary }
        expect(before != nil && before == after && after?.allKeys.count == 3, "re-saving such a note adds nothing to it")
        expect(legacy?.contentBounds == legacy?.pkDrawing.bounds, "its content bounds are just the ink")

        let legacyWithPicture = InkDocument(paper: .lined, drawing: Data(), images: [photo]).encoded()
        let reopened = InkDocument.decode(legacyWithPicture)
        expect(reopened?.images == [photo] && (reopened?.texts ?? []).isEmpty, "a note with only a picture opens as before")
        expect(!String(decoding: reopened?.encoded() ?? Data(), as: UTF8.self).contains("texts"),
               "…and doesn't gain a texts key")
        expect(!String(decoding: InkDocument(texts: []).encoded(), as: UTF8.self).contains("texts"),
               "an empty list of texts is left out of the file")

        let first = InkText(id: "t1", text: "Line one\nLine “two” — ✓ 日本語 😀 \"quoted\" \\ slash/", origin: CGPoint(x: 40, y: 64), width: 600)
        let second = InkText(id: "t2", text: "Second", origin: CGPoint(x: 100, y: 320), width: 300)
        let both = textDoc([baseStroke], images: [photo], texts: [first, second], paper: .grid)
        let back = InkDocument.decode(both)
        expect(back?.texts == [first, second], "typed text round-trips exactly, in order, including newlines and Unicode")
        expect(back?.pkDrawing.strokes.count == 1 && back?.images == [photo] && back?.paper == .grid && back?.version == 1,
               "…and the ink, pictures, paper and version beside it are untouched")
        expect(InkDocument.decode(back?.encoded() ?? Data())?.texts == [first, second], "a second save/open changes nothing")

        let frame = first.frame
        expect(frame.origin == CGPoint(x: 40, y: 64) && frame.width == 600, "text sits where it was put, as wide as asked")
        expect(frame.height >= 2 * InkText.lineHeight
               && frame.height.truncatingRemainder(dividingBy: InkText.lineHeight) == 0, "two lines are two whole ruled lines tall")
        let long = InkText(text: String(repeating: "wrapping words ", count: 40), origin: .zero, width: InkText.minimumWidth)
        expect(long.frame.height > 4 * InkText.lineHeight, "long text wraps and grows downwards")

        var bounds = back?.contentBounds ?? .null
        expect(bounds.contains(first.frame) && bounds.contains(second.frame) && bounds.contains(photo.frame)
               && bounds.contains(back?.pkDrawing.bounds ?? .zero), "content bounds cover ink, pictures and text")
        bounds = InkDocument.decode(textDoc(texts: [second]))?.contentBounds ?? .null
        expect(bounds == second.frame, "a page with only text has just that text as its content (embeds and the AI use this)")

        let placed = InkText.placement(at: CGPoint(x: 100, y: 75))
        expect(placed.origin.y == 64 && placed.origin.x == 100, "new text snaps to the ruled line it was placed on")
        expect(placed.width >= InkText.minimumWidth && placed.origin.x + placed.width <= InkDocument.pageWidth,
               "new text wraps inside the page")
        let edge = InkText.placement(at: CGPoint(x: 5000, y: -20))
        expect(edge.origin.y >= 0 && edge.width >= InkText.minimumWidth && edge.origin.x + edge.width <= InkDocument.pageWidth,
               "placing text off the page keeps it on the page")
    }

    print("12c. Merging two devices' edits to a note's text")
    do {
        let milk = InkText(id: "t1", text: "Buy milk", origin: CGPoint(x: 40, y: 64), width: 500)
        let extra = InkText(id: "t2", text: "Call Sam", origin: CGPoint(x: 40, y: 160), width: 500)
        let newStroke = stroke(y: 300, at: t0.addingTimeInterval(30))
        let base = textDoc([baseStroke], images: [photo], texts: [milk])

        func merged(base: Data?, ours: Data, theirs: Data) -> InkDocument? {
            InkMerge.merge(base: base, ours: ours, theirs: theirs).flatMap(InkDocument.decode)
        }

        // Text added here, ink added there: everything is kept, pictures included.
        var result = merged(base: base,
                            ours: textDoc([baseStroke], images: [photo], texts: [milk, extra]),
                            theirs: textDoc([baseStroke, newStroke], images: [photo], texts: [milk]))
        expect(result?.texts?.map(\.id).sorted() == ["t1", "t2"] && result?.pkDrawing.strokes.count == 2
               && result?.images == [photo], "text added on one device and ink on the other both survive")

        // Text added on both devices.
        let theirNew = InkText(id: "t3", text: "Read chapter 3", origin: CGPoint(x: 40, y: 224), width: 500)
        result = merged(base: base,
                        ours: textDoc([baseStroke], images: [photo], texts: [milk, extra]),
                        theirs: textDoc([baseStroke], images: [photo], texts: [milk, theirNew]))
        expect(Set(result?.texts?.map(\.id) ?? []) == ["t1", "t2", "t3"], "text added on both devices is all kept")

        // Edited on one side only.
        var oat = milk
        oat.text = "Buy oat milk"
        result = merged(base: base, ours: base, theirs: textDoc([baseStroke], images: [photo], texts: [oat]))
        expect(result?.texts == [oat], "an edit made on the other device is taken")
        result = merged(base: base, ours: textDoc([baseStroke], images: [photo], texts: [oat]), theirs: base)
        expect(result?.texts == [oat], "an edit made on this device is kept")

        // Deleted on either side.
        result = merged(base: base, ours: base, theirs: textDoc([baseStroke], images: [photo]))
        expect((result?.texts ?? []).isEmpty && result?.pkDrawing.strokes.count == 1 && result?.images == [photo],
               "text deleted on the other device stays deleted, ink and pictures stay")
        expect(!String(decoding: InkMerge.merge(base: base, ours: base, theirs: textDoc([baseStroke], images: [photo])) ?? Data(),
                       as: UTF8.self).contains("texts"), "…and the file has no texts key left")
        result = merged(base: base, ours: textDoc([baseStroke], images: [photo]), theirs: base)
        expect((result?.texts ?? []).isEmpty, "text deleted on this device stays deleted")

        // Deleted on one device, reworded on the other: the rewording wins, nothing typed is lost.
        result = merged(base: base, ours: textDoc([baseStroke], images: [photo]),
                        theirs: textDoc([baseStroke], images: [photo], texts: [oat]))
        expect(result?.texts == [oat], "text reworded on one device and deleted on the other is kept")

        // Moved on one device, reworded on the other: both changes apply.
        var moved = milk
        moved.origin = CGPoint(x: 80, y: 480)
        result = merged(base: base, ours: textDoc([baseStroke], images: [photo], texts: [moved]),
                        theirs: textDoc([baseStroke], images: [photo], texts: [oat]))
        expect(result?.texts?.count == 1 && result?.texts?.first?.text == "Buy oat milk"
               && result?.texts?.first?.origin == moved.origin, "a move here and new wording there both apply")

        // Reworded differently on both: this device's wording stays in place and the other's is kept too.
        var ours = milk, theirs = milk
        ours.text = "Buy two litres of milk"
        theirs.text = "Buy almond milk"
        result = merged(base: base, ours: textDoc([baseStroke], images: [photo], texts: [ours]),
                        theirs: textDoc([baseStroke], images: [photo], texts: [theirs]))
        let kept = result?.texts ?? []
        expect(kept.count == 2 && kept.first(where: { $0.id == "t1" })?.text == ours.text
               && kept.contains { $0.id != "t1" && $0.text == theirs.text },
               "conflicting rewordings keep this device's text and the other's as a copy")
        if let copy = kept.first(where: { $0.id != "t1" }) {
            expect(copy.y > ours.y && copy.x == ours.x, "the copy sits below the original instead of on top of it")
        }

        // Conflict copies from an earlier merge survive later conflicts on the same text.
        do {
            let conflicted = merged(base: base, ours: textDoc([baseStroke], images: [photo], texts: [ours]),
                                    theirs: textDoc([baseStroke], images: [photo], texts: [theirs]))
            let firstRound = conflicted?.texts ?? []
            let almond = theirs.text
            // Both devices now hold the merged note; each rewords the original line again.
            var again = firstRound
            var other = firstRound
            if let i = again.firstIndex(where: { $0.id == "t1" }) { again[i].text = "Buy semi-skimmed milk" }
            if let i = other.firstIndex(where: { $0.id == "t1" }) { other[i].text = "Buy soy milk" }
            let secondRound = merged(base: conflicted.flatMap { $0.encoded() },
                                     ours: textDoc([baseStroke], images: [photo], texts: again),
                                     theirs: textDoc([baseStroke], images: [photo], texts: other))
            let words = (secondRound?.texts ?? []).map(\.text)
            let ids = (secondRound?.texts ?? []).map(\.id)
            expect(words.contains("Buy semi-skimmed milk") && words.contains("Buy soy milk") && words.contains(almond),
                   "a second conflict keeps this device's wording, the other's, and the copy from the first conflict (\(words))")
            expect(Set(ids).count == ids.count && ids.count == words.count, "…every text keeping its own id (\(ids))")
            expect(words.filter { $0 == almond }.count == 1, "…and the earlier copy isn't duplicated")

            // A copy this device already holds (not yet in the shared base) isn't overwritten by a new one.
            let heldCopy = InkText(id: "t1-conflict", text: "Held copy", origin: CGPoint(x: 40, y: 224), width: 500)
            var mine = ours
            mine.text = "Buy two litres of milk"
            let collided = merged(base: base,
                                  ours: textDoc([baseStroke], images: [photo], texts: [mine, heldCopy]),
                                  theirs: textDoc([baseStroke], images: [photo], texts: [theirs]))
            let collidedWords = (collided?.texts ?? []).map(\.text)
            let collidedIDs = (collided?.texts ?? []).map(\.id)
            expect(Set(collidedWords) == [mine.text, "Held copy", theirs.text] && Set(collidedIDs).count == collidedIDs.count,
                   "a new conflict copy never replaces a copy already on the page (\(collidedWords))")

            // Merging again with nothing new changes nothing: no more copies appear.
            let settled = merged(base: conflicted.flatMap { $0.encoded() },
                                 ours: textDoc([baseStroke], images: [photo], texts: firstRound),
                                 theirs: textDoc([baseStroke], images: [photo], texts: firstRound))
            expect(settled?.texts == firstRound, "merging an already-merged note again adds no copies")
        }

        // No common ancestor (both devices started the note): union.
        result = merged(base: nil, ours: textDoc(texts: [extra]), theirs: textDoc(texts: [theirNew]))
        expect(Set(result?.texts?.map(\.id) ?? []) == ["t2", "t3"], "without a common ancestor, both devices' text is kept")

        // Notes with no text anywhere stay exactly as they were.
        let plainBase = textDoc([baseStroke], images: [photo])
        let plain = InkMerge.merge(base: plainBase, ours: plainBase, theirs: textDoc([baseStroke, newStroke], images: [photo]))
        expect(plain.map { !String(decoding: $0, as: UTF8.self).contains("texts") } == true
               && decoded(plain)?.pkDrawing.strokes.count == 2, "merging notes without text adds no text")
        // A note from before text existed merges with one that has text.
        let drawing = PKDrawing(strokes: [baseStroke]).dataRepresentation().base64EncodedString()
        let legacy = Data(#"{"drawing":"\#(drawing)","paper":"lined","version":1}"#.utf8)
        result = merged(base: legacy, ours: legacy, theirs: textDoc([baseStroke], texts: [milk]))
        expect(result?.texts == [milk] && result?.pkDrawing.strokes.count == 1, "an old note merges with a note that gained text")
    }

    print("12d. The open note: adding, editing, moving and deleting text, saved and reopened")
    do {
        let url = work.appendingPathComponent("Typed.ink")
        try textDoc([baseStroke], images: [photo], paper: .grid).write(to: url)
        MainActor.assumeIsolated {
            let model = InkNoteModel(url: url)
            expect(model.texts.isEmpty, "a note without text opens with none")
            expect(model.addText("   \n ", at: CGPoint(x: 100, y: 100)) == nil && model.texts.isEmpty, "blank text isn't added")

            let added = model.addText("Typed on the page", at: CGPoint(x: 300, y: 200))
            expect(added?.text == "Typed on the page" && model.texts.count == 1, "adding text puts it on the page")
            expect(added.map { $0.origin.y == 192 && $0.origin.x == 300 } == true, "…on the ruled line that was tapped, where it was tapped")
            model.saveNow()
            var onDisk = decoded(try? Data(contentsOf: url))
            expect(onDisk?.texts?.map(\.text) == ["Typed on the page"], "typed text is saved")
            expect(onDisk?.pkDrawing.strokes.count == 1 && onDisk?.images == [photo] && onDisk?.paper == .grid,
                   "…without disturbing the ink, picture or paper")

            guard let id = added?.id else { return }
            model.updateText(id, to: "Typed, then edited\nover two lines")
            model.moveText(id, to: CGPoint(x: 64, y: 480))
            model.saveNow()
            expect(texts(at: url).first.map { $0.id == id && $0.text == "Typed, then edited\nover two lines" && $0.origin == CGPoint(x: 64, y: 480) } == true,
                   "editing and moving text is saved under the same id")

            // Reopening brings it all back.
            let reopened = InkNoteModel(url: url)
            expect(reopened.texts == model.texts && reopened.drawing.strokes.count == 1 && reopened.images == [photo],
                   "reopening the note brings back its text, ink and picture")

            // Ink drawn afterwards doesn't drop the text.
            var drawing = reopened.drawing
            drawing.strokes.append(stroke(y: 400, at: t0.addingTimeInterval(5)))
            reopened.drawingChanged(drawing)
            reopened.saveNow()
            onDisk = decoded(try? Data(contentsOf: url))
            expect(onDisk?.pkDrawing.strokes.count == 2 && onDisk?.texts?.count == 1, "writing after typing keeps the text")

            // A sync brings new text from the other device.
            let other = InkText(id: "from-ipad", text: "Typed elsewhere", origin: CGPoint(x: 40, y: 800), width: 400)
            var arrived = decoded(try? Data(contentsOf: url)) ?? InkDocument()
            arrived.texts = (arrived.texts ?? []) + [other]
            try? arrived.encoded().write(to: url)
            reopened.reloadIfChangedOnDisk()
            expect(reopened.texts.contains(other), "text that arrives from another device appears in the open note")

            // Emptying text removes it; so does deleting it.
            reopened.updateText("from-ipad", to: "  \n")
            expect(!reopened.texts.contains { $0.id == "from-ipad" }, "emptying a text deletes it")
            reopened.removeText(id)
            expect(reopened.texts.isEmpty, "deleting text removes it")
            reopened.saveNow()
            let final = try? Data(contentsOf: url)
            expect(textsOf(final).isEmpty && decoded(final)?.pkDrawing.strokes.count == 2 && decoded(final)?.images == [photo],
                   "deleted text is gone from the file; ink and picture stay")
            expect(!String(decoding: final ?? Data(), as: UTF8.self).contains("texts"), "…and the file has no texts key left")
            expect(InkNoteModel(url: url).texts.isEmpty, "reopening shows no text")
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12d2. Typing in an open editor is autosaved without anything flushing it")
    do {
        let url = work.appendingPathComponent("Autosave.ink")
        let kept = InkText(id: "kept", text: "Already on the page", origin: CGPoint(x: 40, y: 64), width: 600)
        try textDoc([baseStroke], images: [photo], texts: [kept]).write(to: url)
        MainActor.assumeIsolated {
            let model = InkNoteModel(url: url)
            // The canvas does this when an editor opens on new text, then on every keystroke.
            var draft = InkText(id: "draft", text: "Half typed", origin: CGPoint(x: 64, y: 160), width: 600)
            model.editingTextID = draft.id
            model.updateTextDraft(draft)
            expect(model.texts == [kept], "text being typed isn't on the page's text list until the editor closes")
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))   // past the 1.5 s autosave, no saveNow()
            var saved = texts(at: url)
            expect(saved.map(\.text) == ["Already on the page", "Half typed"],
                   "an open editor's new text is autosaved (\(saved.map(\.text)))")
            expect(decoded(try? Data(contentsOf: url))?.pkDrawing.strokes.count == 1 && decoded(try? Data(contentsOf: url))?.images == [photo],
                   "…without disturbing the ink or picture")

            draft.text = "Half typed, then the rest"
            model.updateTextDraft(draft)
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            saved = texts(at: url)
            expect(saved.map(\.text) == ["Already on the page", "Half typed, then the rest"],
                   "more typing is autosaved too, in the same text (\(saved.map(\.text)))")

            // Blank text is never saved, even while it is only a draft.
            draft.text = "  \n "
            model.updateTextDraft(draft)
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            expect(texts(at: url).map(\.id) == ["kept"], "an editor emptied while open leaves nothing saved for it")

            // Editing text that is already on the page replaces it in place.
            var edit = kept
            edit.text = "Already on the page, reworded"
            model.updateTextDraft(edit)
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            saved = texts(at: url)
            expect(saved.count == 1 && saved.first?.id == "kept" && saved.first?.text == edit.text,
                   "editing existing text autosaves under its own id, not as a copy (\(saved.map(\.text)))")

            // Closing the editor makes the text part of the page; nothing is left over from the draft.
            model.updateTextDraft(nil)
            model.editingTextID = nil
            model.updateText("kept", to: edit.text)
            model.saveNow()
            expect(texts(at: url).map(\.text) == [edit.text] && model.texts.map(\.text) == [edit.text],
                   "closing the editor leaves one copy of the text")
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }
}
