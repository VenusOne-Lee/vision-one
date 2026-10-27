# Versions: one demo, many people

Paste a list of names and Vision One makes a copy of the take for each person, with their name and company on the opening title card. Open it from the people button in the editor. Visual overview: [Versions and languages](https://claude.ai/artifact/6ZTgVYocinRVTqByVuU18K).

## The list

`RecipientList.parse` takes what people copy out of a sheet, an email or a CRM:

- A header row in any order and case (name, first name, surname, company, email, language, plus any other column), in English, Afrikaans or isiZulu. A row with a digit or an email address is never taken as a header.
- No header: the cell with an @ is the email, "Name <email>" is split, the first other cell is the name and the next the company. A name is made from the email when there's nothing else.
- Commas, tabs (pasted from a spreadsheet) or semicolons (South African Excel exports), quoted cells and a BOM.
- Repeats (same email, or same name and company) are skipped and counted. Rows without a name are listed, never dropped quietly. At most 200 people at a time.

## The title card

Two lines, each a template: `Made for {first name|you}` and `{company}` by default. Any column works as a field, and a fallback goes after a bar. When a field is empty and has no fallback, the word leaning on it goes too ("Hi Sipho from {company}" becomes "Hi Sipho"). The card is the brand intro card (`NativeCard` with `headline`/`subline`), so it uses the brand kit's colours and ring. It can be turned off; files are still named after each person.

If the list has a language column and the take has captions in that language, that person's copy uses them.

## Making them

Each copy is a full export, one after the other, into `<take>/Versions/` as `<Name> - <Company>.mp4` (names that would collide get " 2"). `versions.csv` is written beside them for a mail merge, with a status column, and cells starting with = + - @ are escaped so spreadsheets don't run them. Nothing leaves the Mac. The job shows on the agents board as the Producer, and the card lines are saved as `versions.json` in the take folder.

Later: encode the video once and only re-render the card for each person.
