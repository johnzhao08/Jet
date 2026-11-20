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

    print("12d3. Moving text right, and tapping the unused part of a line")
    do {
        let url = work.appendingPathComponent("Moving.ink")
        try textDoc([baseStroke]).write(to: url)
        MainActor.assumeIsolated {
            let model = InkNoteModel(url: url)
            guard let added = model.addText("Hi", at: CGPoint(x: 40, y: 192), id: "short") else {
                failures += 1
                print("  FAIL  text wasn't added")
                return
            }
            let startWidth = added.width

            // Text starts out wrapping at the page's right margin, so it must be able to move right
            // by giving up wrap width instead of being stuck against that margin.
            model.moveText("short", to: CGPoint(x: 400, y: 192))
            var moved = model.texts.first
            expect(moved?.origin == CGPoint(x: 400, y: 192), "text can be moved well to the right (at \(moved?.origin ?? .zero))")
            expect(moved.map { $0.x + $0.width <= InkDocument.pageWidth && $0.width >= InkText.minimumWidth && $0.width < startWidth } == true,
                   "…and wraps inside the page afterwards (width \(moved?.width ?? 0))")
            model.moveText("short", to: CGPoint(x: 5000, y: 192))
            moved = model.texts.first
            expect(moved.map { $0.x + $0.width <= InkDocument.pageWidth && $0.width >= InkText.minimumWidth && $0.x > 400 } == true,
                   "moving it far off the right keeps it on the page at least its minimum width (\(moved?.origin ?? .zero), \(moved?.width ?? 0))")
            model.moveText("short", to: CGPoint(x: 400, y: 192))
            model.saveNow()
            expect(texts(at: url).first.map { $0.origin == CGPoint(x: 400, y: 192) && $0.text == "Hi" } == true,
                   "a text moved right is saved there, with its words")
            expect(InkNoteModel(url: url).texts.first?.origin == CGPoint(x: 400, y: 192), "…and reopens there")

            // A long text moved right wraps onto more lines but keeps every word.
            let sentence = String(repeating: "wrapping words ", count: 12).trimmingCharacters(in: .whitespaces)
            let long = model.addText(sentence, at: CGPoint(x: 40, y: 480), id: "long")
            let linesBefore = long.map { $0.frame.height / InkText.lineHeight } ?? 0
            model.moveText("long", to: CGPoint(x: 600, y: 480))
            let longMoved = model.texts.first { $0.id == "long" }
            expect(longMoved?.text == sentence && longMoved?.origin.x == 600
                   && (longMoved.map { $0.frame.height / InkText.lineHeight } ?? 0) >= linesBefore
                   && (longMoved.map { $0.frame.maxX <= InkDocument.pageWidth } == true),
                   "long text moved right keeps its words and stays on the page")
            model.removeText("long")

            // Hit-testing: only where the text actually is, not the empty rest of its wrap width.
            guard let text = model.texts.first(where: { $0.id == "short" }) else { return }
            let top = text.y
            expect(model.text(at: CGPoint(x: text.x + 4, y: top + InkText.lineHeight / 2))?.id == "short",
                   "a tap on the words finds the text")
            expect(model.text(at: CGPoint(x: text.x + text.width - 20, y: top + InkText.lineHeight / 2)) == nil,
                   "a tap on the empty end of a short line doesn't")
            expect(model.text(at: CGPoint(x: text.x + 4, y: top + InkText.lineHeight + 8)) == nil,
                   "a tap just below the last line doesn't")
            expect(model.text(at: CGPoint(x: text.x - 40, y: top + InkText.lineHeight / 2)) == nil,
                   "a tap left of the text doesn't")

            // A short second line leaves the rest of that line free, though the first line is long.
            model.removeText("short")
            model.addText("A first line that runs a good way across\nok", at: CGPoint(x: 40, y: 640), id: "two")
            guard let two = model.texts.first(where: { $0.id == "two" }) else { return }
            expect(model.text(at: CGPoint(x: two.x + 200, y: two.y + InkText.lineHeight / 2))?.id == "two",
                   "a tap on the long first line finds the text")
            expect(model.text(at: CGPoint(x: two.x + 200, y: two.y + InkText.lineHeight * 1.5)) == nil,
                   "a tap past the end of the short second line doesn't")
            expect(model.text(at: CGPoint(x: two.x + 6, y: two.y + InkText.lineHeight * 1.5))?.id == "two",
                   "a tap on the short second line's words does")

            // Overlapping frames: the tap goes to the text whose words are there.
            model.removeText("two")
            model.addText("A long line of words that goes across the page", at: CGPoint(x: 100, y: 800), id: "wide")
            model.addText("Hi", at: CGPoint(x: 100, y: 800), id: "tiny")
            expect(model.text(at: CGPoint(x: 100 + 220, y: 800 + InkText.lineHeight / 2))?.id == "wide",
                   "a tap on one text's words isn't taken by another text's empty space on top of it")
            expect(model.text(at: CGPoint(x: 100 + 4, y: 800 + InkText.lineHeight / 2))?.id == "tiny",
                   "…and where both have words, the one on top wins")
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12d4. Undo doesn't reach back across a sync that replaced the note")
    do {
        let url = work.appendingPathComponent("UndoSync.ink")
        let kept = InkText(id: "kept", text: "Mine", origin: CGPoint(x: 40, y: 64), width: 600)
        try textDoc([baseStroke], texts: [kept]).write(to: url)
        MainActor.assumeIsolated {
            let model = InkNoteModel(url: url)
            let view = InkSurfaceView(model: model)
            // Wired as InkSurface.makeNSView does.
            model.undo = { [weak view] in view?.undoLast() }
            model.redo = { [weak view] in view?.redoLast() }
            model.textsEdited = { [weak view, weak model] before, name in
                guard let view, let model else { return }
                view.recordTexts(from: before, to: model.texts, name: name)
            }
            @MainActor func configure() {
                view.configure(scale: 1, origin: .zero, tool: .pen, swatch: .black, thickness: .medium,
                               dark: false, generation: model.generation)
            }
            configure()

            model.addText("Typed before the sync", at: CGPoint(x: 100, y: 300), id: "before")
            expect(model.canUndo, "typing text can be undone")
            view.undoLast()
            expect(model.texts.map(\.id) == ["kept"], "undo takes the typed text back off")
            view.redoLast()
            expect(model.texts.map(\.id) == ["kept", "before"], "…and redo puts it back")

            // Another device's text arrives while this one has undo history.
            model.saveNow()
            let other = InkText(id: "from-ipad", text: "Typed elsewhere", origin: CGPoint(x: 40, y: 800), width: 400)
            var arrived = decoded(try? Data(contentsOf: url)) ?? InkDocument()
            arrived.texts = (arrived.texts ?? []) + [other]
            try? arrived.encoded().write(to: url)
            model.reloadIfChangedOnDisk()
            configure()
            expect(model.texts.contains(other), "text from the other device arrived")
            expect(!model.canUndo, "undo history ends when the note is replaced from disk")
            view.undoLast()
            expect(model.texts.map(\.id) == ["kept", "before", "from-ipad"],
                   "undo after a sync neither drops the arrived text nor rolls the page back (\(model.texts.map(\.id)))")

            // Edits after the sync undo normally, and only themselves.
            model.removeText("from-ipad")
            expect(model.canUndo && !model.texts.contains(where: { $0.id == "from-ipad" }), "deleting text after the sync can be undone")
            view.undoLast()
            expect(model.texts.map(\.id) == ["kept", "before", "from-ipad"], "…and undo brings back just that text")
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12d5. Existing text opened in the editor but not typed in yields to a sync that changed or deleted it")
    do {
        let original = InkText(id: "kept", text: "Original wording", origin: CGPoint(x: 40, y: 64), width: 600)
        let bystander = InkText(id: "by", text: "Bystander", origin: CGPoint(x: 40, y: 160), width: 600)
        var reworded = original
        reworded.text = "Reworded on the iPad"
        let remotes: [(name: String, texts: [InkText])] = [("reworded", [reworded, bystander]), ("deleted", [bystander])]
        // What happens after the sync lands, before the note is saved: the canvas may or may not have
        // been reconfigured (which is what notices a reload) by the time the editor closes or a flush happens.
        let orders = ["configure, close, save", "flush, close, save", "close, save"]
        for (r, remote) in remotes.enumerated() {
            for (o, order) in orders.enumerated() {
                let url = work.appendingPathComponent("Untouched-\(r)-\(o).ink")
                try textDoc([baseStroke], texts: [original, bystander]).write(to: url)
                MainActor.assumeIsolated {
                    let label = "\(remote.name) remotely, then \(order)"
                    let model = InkNoteModel(url: url)
                    let view = InkSurfaceView(model: model)
                    model.undo = { [weak view] in view?.undoLast() }
                    model.redo = { [weak view] in view?.redoLast() }
                    model.textsEdited = { [weak view, weak model] before, name in
                        guard let view, let model else { return }
                        view.recordTexts(from: before, to: model.texts, name: name)
                    }
                    @MainActor func configure() {
                        view.configure(scale: 1, origin: .zero, tool: .text, swatch: .black, thickness: .medium,
                                       dark: false, generation: model.generation)
                    }
                    configure()

                    // The writer opens the text to edit it, and types nothing.
                    view.beginTextEditing(model.texts.first { $0.id == "kept" }, at: .zero)
                    model.saveNow()
                    expect(texts(at: url) == [original, bystander], "opening text for editing changes nothing on disk (\(label))")

                    // A sync brings the other device's version of the note, then the writer closes the editor.
                    try? textDoc([baseStroke], texts: remote.texts).write(to: url)
                    model.reloadIfChangedOnDisk()
                    switch o {
                    case 0: configure(); view.endTextEditing()
                    case 1: model.saveNow(); view.endTextEditing()
                    default: view.endTextEditing()
                    }
                    model.saveNow()

                    let saved = texts(at: url)
                    expect(saved == remote.texts, "the other device's change is what stays saved (\(label): \(saved.map(\.text)))")
                    expect(!saved.contains { $0.id == "kept" && $0.text == original.text },
                           "the untouched old wording isn't put back (\(label))")
                    expect(decoded(try? Data(contentsOf: url))?.pkDrawing.strokes.count == 1, "…and the ink is untouched (\(label))")
                    expect(view.undoManager?.canUndo == false && !model.canUndo,
                           "closing an editor nothing was typed in leaves nothing to undo (\(label))")
                    expect(model.editingTextID == nil && model.textDraft == nil, "…and no draft is left behind (\(label))")
                }
            }
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12d6. A new text still being typed survives an unrelated sync of the note")
    do {
        let url = work.appendingPathComponent("NewDraft.ink")
        let kept = InkText(id: "kept", text: "Already here", origin: CGPoint(x: 40, y: 64), width: 600)
        try textDoc([baseStroke], texts: [kept]).write(to: url)
        MainActor.assumeIsolated {
            let model = InkNoteModel(url: url)
            let view = InkSurfaceView(model: model)
            model.undo = { [weak view] in view?.undoLast() }
            model.redo = { [weak view] in view?.redoLast() }
            model.textsEdited = { [weak view, weak model] before, name in
                guard let view, let model else { return }
                view.recordTexts(from: before, to: model.texts, name: name)
            }
            @MainActor func configure() {
                view.configure(scale: 1, origin: .zero, tool: .text, swatch: .black, thickness: .medium,
                               dark: false, generation: model.generation)
            }
            configure()

            // A new, still blank text box is open.
            view.beginTextEditing(nil, at: CGPoint(x: 100, y: 300))
            let draftID = model.editingTextID
            model.saveNow()
            expect(draftID != nil && texts(at: url) == [kept], "a blank new text isn't saved")

            // The other device only adds ink (and a line of its own); this note had no other changes.
            let theirs = InkText(id: "from-ipad", text: "Typed elsewhere", origin: CGPoint(x: 40, y: 800), width: 400)
            try? textDoc([baseStroke, stroke(y: 400, at: t0.addingTimeInterval(9))], texts: [kept, theirs]).write(to: url)
            model.reloadIfChangedOnDisk()
            configure()
            expect(model.texts.contains(theirs) && model.drawing.strokes.count == 2, "the other device's changes arrive while the editor is open")
            expect(model.editingTextID == draftID, "…and the editor is still open on the new text")

            // Typing carries on in the same editor.
            if let editor = view.subviews.compactMap({ $0 as? NSTextView }).first {
                editor.string = "Typed after the sync"
                view.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            } else {
                failures += 1
                print("  FAIL  the editor disappeared when the note reloaded")
            }
            view.endTextEditing()
            model.saveNow()

            let saved = texts(at: url)
            expect(saved.map(\.text) == ["Already here", "Typed elsewhere", "Typed after the sync"],
                   "the new text, the other device's text and the old text are all saved (\(saved.map(\.text)))")
            expect(saved.filter { $0.id == draftID }.count == 1, "…the new text once")
            expect(decoded(try? Data(contentsOf: url))?.pkDrawing.strokes.count == 2, "…with the other device's ink")
            expect(view.undoManager?.canUndo == true, "adding the new text can be undone")
            view.undoLast()
            expect(model.texts.map(\.text) == ["Already here", "Typed elsewhere"],
                   "undo takes back just the new text (\(model.texts.map(\.text)))")
        }
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12e. The AI helper sees typed text")
    do {
        let vault = work.appendingPathComponent("typed-vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let note = InkText(id: "t1", text: "Only typed words", origin: CGPoint(x: 40, y: 64), width: 600)
        try textDoc(texts: [note]).write(to: vault.appendingPathComponent("Typed only.ink"))
        let reply = MCPServer(vault: vault).handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                     "params": ["name": "read_note", "arguments": ["path": "Typed only"]]])
        let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        expect(content.contains { $0["type"] as? String == "image" }, "read_note renders a page that only has typed text")
        expect(!content.contains { ($0["text"] as? String)?.contains("is empty") == true }, "…and doesn't call it empty")
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }

    print("12f. Text on a note, synced between two devices through git")
    do {
        let remote = work.appendingPathComponent("inktext-remote.git")
        let ipad = work.appendingPathComponent("inktext-ipad")
        let mac = work.appendingPathComponent("inktext-mac")
        let author = GitAuthor(name: "Self Test", email: "selftest@jet.local")
        func sync(_ dir: URL, _ device: String) throws -> SyncReport {
            try SyncEngine.sync(vaultPath: dir.path, credentials: nil, author: author, deviceName: device)
        }
        shell("init", "--bare", "--initial-branch=main", remote.path)
        try fm.createDirectory(at: ipad, withIntermediateDirectories: true)
        let repo = try GitRepository.create(at: ipad.path)
        try repo.setRemoteURL(remote.path)

        let milk = InkText(id: "t1", text: "Buy milk", origin: CGPoint(x: 40, y: 64), width: 500)
        let sam = InkText(id: "t2", text: "Call Sam", origin: CGPoint(x: 40, y: 160), width: 500)
        let chapter = InkText(id: "t3", text: "Read chapter 3", origin: CGPoint(x: 40, y: 224), width: 500)
        var oat = milk
        oat.text = "Buy oat milk"
        let oldDrawing = PKDrawing(strokes: [baseStroke]).dataRepresentation().base64EncodedString()
        try Data(#"{"drawing":"\#(oldDrawing)","paper":"lined","version":1}"#.utf8).write(to: ipad.appendingPathComponent("Old.ink"))
        try textDoc([baseStroke], images: [photo], texts: [milk]).write(to: ipad.appendingPathComponent("Plan.ink"))
        var report = try sync(ipad, "iPad")
        expect(report.committed && report.pushed, "iPad pushes a note with text")
        _ = try GitRepository.clone(from: remote.path, to: mac.path, credentials: nil)
        expect(texts(at: mac.appendingPathComponent("Plan.ink")) == [milk], "the Mac clones the typed text")
        expect((texts(at: mac.appendingPathComponent("Old.ink"))).isEmpty
               && decoded(try? Data(contentsOf: mac.appendingPathComponent("Old.ink")))?.pkDrawing.strokes.count == 1,
               "a note from before text existed clones fine")

        // iPad rewords one line and adds another; the Mac adds ink and a line of its own.
        let macStroke = stroke(y: 300, at: t0.addingTimeInterval(60))
        try textDoc([baseStroke], images: [photo], texts: [oat, sam]).write(to: ipad.appendingPathComponent("Plan.ink"))
        try textDoc([baseStroke, macStroke], images: [photo], texts: [milk, chapter]).write(to: mac.appendingPathComponent("Plan.ink"))
        // And the old note gains text on iPad while the Mac draws on it.
        try textDoc([baseStroke], texts: [sam]).write(to: ipad.appendingPathComponent("Old.ink"))
        try textDoc([baseStroke, macStroke]).write(to: mac.appendingPathComponent("Old.ink"))
        _ = try sync(ipad, "iPad")
        report = try sync(mac, "Mac")
        expect(report.conflicts.sorted() == ["Old.ink", "Plan.ink"], "both edited notes are merged, not copied")
        let copies = (try? fm.contentsOfDirectory(atPath: mac.path).filter { $0.contains("conflict") || $0.hasPrefix("Plan (") }) ?? []
        expect(copies.isEmpty, "no conflict copy for ink notes with text")
        let plan = decoded(try? Data(contentsOf: mac.appendingPathComponent("Plan.ink")))
        expect(Set(plan?.texts?.map(\.id) ?? []) == ["t1", "t2", "t3"] && plan?.texts?.first(where: { $0.id == "t1" })?.text == "Buy oat milk",
               "merged note has the reworded line and both added lines")
        expect(plan?.pkDrawing.strokes.count == 2 && plan?.images == [photo], "…and the Mac's ink and the picture")
        let old = decoded(try? Data(contentsOf: mac.appendingPathComponent("Old.ink")))
        expect(old?.texts?.map(\.id) == ["t2"] && old?.pkDrawing.strokes.count == 2, "an old note merges with text added on the other device")
        _ = try sync(ipad, "iPad")
        expect(texts(at: ipad.appendingPathComponent("Plan.ink")) == plan?.texts
               && texts(at: ipad.appendingPathComponent("Old.ink")) == old?.texts, "the iPad converges on the merged text")

        // A line deleted on one device while the other leaves it alone.
        try textDoc([baseStroke, macStroke], images: [photo], texts: [oat, chapter]).write(to: mac.appendingPathComponent("Plan.ink"))
        _ = try sync(mac, "Mac")
        _ = try sync(ipad, "iPad")
        expect(Set(texts(at: ipad.appendingPathComponent("Plan.ink")).map(\.id)) == ["t1", "t3"], "a deleted line is deleted on the other device")
    } catch {
        failures += 1
        print("  FAIL  threw: \(error.localizedDescription)")
    }
}
