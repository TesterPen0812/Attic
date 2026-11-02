# iPhone Planning

The drawing is the spec: `../improvements-build/iphone-inspired/index.html`, plus `../improvements-build/iphone-calendar-drafts/index.html` for Calendar (where the two differ, the Calendar sheet wins).
Only Accepted items get built. Building also waits for the Development Contract update (AGENTS.md / claude.md) and a written activation and validation plan.

## Accepted

### 2026-11-01 · Rules, no drawing needed
- **Designed the way the Mac was:** rough drafts, the owner's pick, then one working drawing with this Planning file. The owner: "lets redesign the mobile app, similarly to how we deisgned the app in html".
- **Building is separate:** it needs the Development Contract update and a written activation and validation plan first (owner, 19 Oct and 1 Nov).
- Accepted: owner, 1 Nov.

### 2026-11-01 · Its own phone-first look (no drawing)
- The iPhone doesn't copy the Mac's look (segmented controls, tag bars, glass buttons, row metrics). It keeps Attic's content and identity, designed phone-first.
- The owner: "its mobile, we can have a different design for mobile thats optimised and more beautiful for mobile".
- Accepted: owner, 1 Nov.

### 2026-11-01 · One design inspired by the reference app
- One iPhone design that takes its inspiration from the owner's reference app (Home and Tasks screenshots), in Attic's own terms. Not a literal copy of its parts (look 4, "Native + pills", was turned down), and not a pick between three looks.
- The owner: "no, lets just inspire from this".
- Accepted: owner, 1 Nov. (This accepts the direction; the page-by-page items below still wait for an OK.)

### 2026-11-02 · Calendar: A + rows 2 (`iphone-calendar-drafts/`)
- **Top (A):** under the "October 2026" title, only this week shows as a strip, with a grab bar under it. Pulling down grows the strip into the whole month, and the list moves down.
- **Rows (2):** the time sits in a fixed grey column on the left ("All day" for all-day events). Events show their calendar colour only on the dot; tasks show their ring. No time chip.
- **Shared parts of every draft:** today is a plain blue circle holding only its number, with its dots under it. Day headings have no calendar icon and no •••.
- The owner: "For the mobile app, For calendar, let's go with the A+2."
- Accepted: owner, 2 Nov.

## Backlog: drawn, waiting for the owner's OK

**Say OK and every item below moves to Accepted.**

Drawn in `iphone-inspired/index.html` (1 Nov, Heading fix v3). Items marked *(orch)* are orchestrator decisions, from the reference screenshots ("since you have the ss, you create the mobile version").

### Shared look and chrome
- A plain white or black ground with almost no boxes. Plain 44 pt rows.
- Big left-aligned page titles with space above them; on scroll the title moves into the top bar.
- Section headings: a grey icon, the name in 17 pt semibold, ••• right after it, and a collapse ⌄ at the far right. Names only, no date *(orch)*. Calmer icons and size *(orch, after the owner's "this loosk obnoxious")*: Overdue's icon isn't red; overdue shows on the rows instead.
- Rows end in right-aligned rounded chips: blue for dates and times, red for overdue, grey for done items and note times. Overdue tasks also get a red ring.
- Task rows show dates only, no tag chips *(orch)*. They keep the segmented ring, the dashed ring for Later, "!!" priority and a small glyph when the task has writing.
- Bottom left: an icon-only tab capsule (Home, Tasks, Calendar). The current tab is filled, tinted and set on a soft inner pill.
- Bottom right, at the thumb: one capsule with Search beside "+" *(orch)*.
- Top right: ••• alone in a small capsule *(orch)*. Pushed pages (All notes, Canvases, a canvas, a note) get a round Back at the top left.
- Glass only on the capsules: tabs, the thumb capsule, •••, Back, the format bar and the Draw tools.
- No avatar, bell or assistant.
- Motion uses the Mac's engine (`attic-motion.js`): pages slide in tab order; a note and Search fade in.

### Home
- Title "Home", then a grey Search field.
- A sideways row of recent cards (150 × 185): title, hairline, live preview (a note with its image, today's tasks with rings and the next event, a canvas, a note with its table). The third card is cut off at the edge. A tap opens it.
- Two plain link rows: All notes, Canvases.
- "Pinned ›" (opens All notes) with the pinned notes as rows.
- "Tags ›": each tag as a row with its hued #, name and count. Its ⌄ opens that tag's notes in place.

### Tasks
- Title "Tasks", then one pill row: Now · Later · Done. Only the current pill shows its name, tinted blue; the others are grey icons.
- Now: Overdue, Today (the next event row at the top, e.g. "16:30 Launch sync"), Tomorrow, the days after, No date. Later: one list. Done: "This week".
- ••• opens a Tags menu, each tag with its open-task count *(orch)*. A picked tag filters the list and joins the pill row as a tinted pill with ✕.
- Swipe a row left for Later and Done; swipe back to close.

### Calendar (rest of the Calendar sheet, beyond the Accepted pick)
- Day headings read "Today Wed 28 Oct", "Tomorrow Thu 29 Oct", then the weekday and date, with the collapse ⌄. The date is the drafter's addition, shown in every draft.
- Past events today have grey titles. Tasks with a time appear in the agenda among the events.

### Notes list and editor
- All notes (from Home): sections Pinned, Today, This week, Earlier; rows with a note glyph, title and a grey time chip.
- A picked tag filters All notes and shows as a pill with ✕.
- Editor: Back at the top left; one capsule at the top right with ••• and a blue Done ✓. A big title, the tag line under it, "Edited …", then the writing: checklists, tables, images and a date line.
- While typing, a format bar sits above the keyboard: Aa, checklist, bullets, table, photo, Undo, hide keyboard.

### Canvases and Draw
- Canvases (from Home): rows with a draw glyph, the name and a grey date chip. A tap opens the canvas.
- A canvas: its name as the big title, then the board.
- The Draw tool capsule (Select, Pen, Eraser, Text, Shape, the swatch, Undo) takes the tab capsule's place. "+" at the thumb starts a new, untitled canvas.
- Back returns to where the canvas was opened from (Canvases or Home).

### Search
- Tapping Home's own field: the field rises to the top. Tapping Search in the thumb capsule: the field grows above the keyboard *(orch)*.
- Results are grouped Tasks, Notes, Calendar, each with a count; the match is highlighted. ✕ closes.

### "+" quick capture
- "+" grows into a card above the keyboard. Its top-right switch is Task · Note, or Task · Event · Note on Calendar.
- The title line tints what it reads (a day and time, #tag, "!!"); the second line is the writing.
- Chips: Task has date, priority and tag; Note has tag and Pin; Event has time, length and calendar. Then Create.
- A tap outside the card closes it.

### Adaptive behaviours
- On Home, Search joins "+" only after Home's own field scrolls away *(orch)*.
- A collapsed section shows its count where its rows were.
- A picked tag joins the pill row (grows from the menu it was picked in).
- On a canvas, the tool capsule takes the tab capsule's place.

## Gap to the Mac

Mac Accepted and Built features the iPhone drawing doesn't cover yet.

**Draw it** · drawn 2026-11-02 by Claude (Opus) in `improvements-build/iphone-gap/` (35 screens; not yet reviewed by the owner). Astra builds to it tonight on `iphone/build`.
- A task's page (head + writing, subtasks), how a row opens it, and Back to the same tab and position.
- Editing a task's title in place (the Mac's double-click).
- Files on task rows: tiles under the row that scroll sideways.
- Multi-select with a selection bar (T2), and dragging a task under another day to change its date.
- Search: counts per Now · Later · Done (T3), and a Canvases group (name, #tag, text on the board).
- "+" card: Priority widening in place (P1), and the "Added to Notes" notice for a quick note.
- Calendar: an event opening in place (C1, edit Attic's own with Undo, "Open in Calendar" for others), and a way back to today (C3).
- Notes: a board view; the note ••• menu (Pin, Add to Tasks / Remove from Tasks, Delete); task notes in the list.
- Notes editor: the style list from Aa (N1), highlight colours (N2), the link field (N3), Find in a note (N4), the "Claude has changes" review (N5), editing tags as chips (N6), "+" on an open note (N7).
- Draw: the canvas menu (rename, Tags…, Duplicate, Export…, Copy as Image, Delete, switching canvases), Shape and swatch widening (D1), Pen and Text widths (D2), selection with handles and its bar and Style (D3), the zoom pill (D5).
- Settings, and what each page's ••• holds (only Tasks' ••• is drawn).

**Same as Mac, no drawing needed**
- The adaptive UI rules (guard rails still unconfirmed by the owner).
- Direction and rules: four pages, a task and its writing are one item, Apple Calendar owns events, Calendar writes, one date per task, no alerts, no flags, links live in the writing.
- Events are created only on Calendar; "+" elsewhere makes a task or a note.
- Later is the backlog: a date moves a task to Now; moving to Later clears it.
- The next event in Now, behind its switch.
- Done's tag filter keeps working (T6).
- The "+" card keeps its draft on dismiss; Later makes a put-off task.
- Selected rows use a grey fill; shared controls stay still while pages switch; expanded things close with ✕ or a tap outside.
- Squircle surfaces and curve-1.4 controls; segmented ring; tag hues.
- Draw: the board (dots), pinch to zoom, smoothed ink, whole-stroke eraser, Text boxes, shapes, no Clear Canvas; the new Canvas starts empty and has its own saver.
- Reduce Motion and Reduce Transparency fallbacks.

**Mac-only (panel, island, hover reveal)**
- The tall island, its position setting, pulling a page out (S1).
- Pin, the top row and the bottom bar with its tag bar (and its edge fades and width).
- Hover reveals: the › on rows, the ring's hover check, ••• on hover.
- Click activation and focus outlines; keyboard shortcuts (Draw keys, ⇧⌘I, ⇧⌘N, ⌘Return).
- Menus at 16 pt; the Mac's Calendar agenda tiles and big ink key (the iPhone's A + rows 2 replaces them).

## Built

Nothing is built yet.
