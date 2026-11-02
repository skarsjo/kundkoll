-- Soker mejl till eller fran en kunds adresser i Mail och sparar bilagorna.
--
-- Anropas som:
--   osascript mail-sok.applescript <bilagemapp> <max mejl per lada> <max bilagor per lada> <adress> [adress ...]
--
-- Allt for en kund gors i en korning. Tidigare kordes ett skript per adress
-- for mejlen och ett till per adress for bilagorna, och Mail fick filtrera
-- samma ladar upp till tio ganger i rad. Mail svarar pa AppleScript i sin
-- egen huvudtrad, sa under tiden stod det och snurrade. Nu filtreras varje
-- lada en gang per adress, och bilagorna tas ur samma traffar.
--
-- Gransen galler per lada och adress, inte totalt. Annars skulle inkorgen
-- fylla hela kvoten och skickade mejl aldrig komma med. Anroparen sorterar pa
-- datum.
--
-- Svaret har tva delar, skilda av en rad med bara ASCII 30 (record
-- separator): forst en rad per mejl, sedan en rad per sparad bilaga. Falten
-- ar atskilda av ASCII 31 (unit separator), eftersom amnesrader garna
-- innehaller bade tabbar och rortecken.
--   mejl:   datum | avsandare | amne | meddelande-id | konto | lada | riktning | brodtext
--   bilaga: amne | filnamn | sokvag | storlek
--
-- AppleScript-identifierare maste vara ASCII, darav stavningen har.
-- Kommentarer far daremot innehalla å ä ö.
--
-- Inkorgen filtreras på avsändare, skickat på mottagare. Att filtrera på
-- avsändare även i skickat vore meningslöst: där är avsändaren alltid jag.

on run argv
	set malmapp to item 1 of argv
	set gransMejl to (item 2 of argv) as integer
	set gransBilagor to (item 3 of argv) as integer
	set adresser to items 4 thru -1 of argv
	set faltdelare to (ASCII character 31)
	set mejlut to ""
	set bilagaut to ""

	tell application "Mail"
		repeat with konto in accounts
			set kontonamn to name of konto

			-- "sent mailbox of konto" finns inte i Mails ordlista, och lådan
			-- heter olika beroende på konto och språk, så namnen provas i tur.
			-- Det görs en gång per konto, inte per adress.
			set skickatnamn to ""
			repeat with kandidat in {"Sent Messages", "Sent", "Skickat", "Skickade objekt"}
				try
					get name of mailbox (kandidat as string) of konto
					set skickatnamn to kandidat as string
					exit repeat
				end try
			end repeat

			repeat with adress in adresser
				set adress to adress as string

				-- Inkorgen: mejl från personen
				try
					set traffar to (every message of mailbox "INBOX" of konto whose sender contains adress)
					set svar to my samla(traffar, kontonamn, "INBOX", "fran", gransMejl, gransBilagor, malmapp, faltdelare)
					set mejlut to mejlut & item 1 of svar
					set bilagaut to bilagaut & item 2 of svar
				end try

				-- Skickat: mejl till personen
				if skickatnamn is not "" then
					try
						set skickat to mailbox skickatnamn of konto
						set traffar to (every message of skickat whose (address of every to recipient) contains adress)
						set svar to my samla(traffar, kontonamn, skickatnamn, "till", gransMejl, gransBilagor, malmapp, faltdelare)
						set mejlut to mejlut & item 1 of svar
						set bilagaut to bilagaut & item 2 of svar
					end try
				end if
			end repeat
		end repeat
	end tell
	return mejlut & (ASCII character 30) & linefeed & bilagaut
end run

-- Går igenom träffarna i en låda en gång: de första blir mejlrader, och
-- bilagorna sparas tills den egna kvoten är fylld. Egna räknare, så att
-- bilderna i inkorgen inte tränger undan mejlen eller tvärtom.
on samla(traffar, kontonamn, ladnamn, riktning, gransMejl, gransBilagor, malmapp, d)
	set mejltext to ""
	set bilagetext to ""
	set mejlraknare to 0
	set bilageraknare to 0
	tell application "Mail"
		repeat with m in traffar
			if mejlraknare >= gransMejl and bilageraknare >= gransBilagor then exit repeat
			if mejlraknare < gransMejl then
				set mejlraknare to mejlraknare + 1
				set mejltext to mejltext & my rad(m, kontonamn, ladnamn, riktning, d)
			end if
			if bilageraknare < gransBilagor then
				try
					repeat with b in (every mail attachment of m)
						if bilageraknare >= gransBilagor then exit repeat
						try
							-- Namnet kommer fran avsandaren. Ett snedstreck
							-- i det hade pekat ut ur mappen.
							set namn to my rensaNamn(name of b)
							set stl to file size of b
							-- Stora filer hoppas over: de ar sallan text.
							-- Signaturbilder och kalenderfiler sorteras
							-- bort har och inte forst i Swift, annars
							-- raknas de mot kvoten.
							if stl < 26214400 and my varAttSpara(namn) then
								set malfil to malmapp & "/" & namn
								save b in POSIX file malfil
								set bilageraknare to bilageraknare + 1
								set bilagetext to bilagetext & (subject of m) & d & namn & d & malfil & d & (stl as string) & linefeed
							end if
						end try
					end repeat
				end try
			end if
		end repeat
	end tell
	return {mejltext, bilagetext}
end samla

on rad(m, kontonamn, ladnamn, riktning, faltdelare)
	tell application "Mail"
		try
			set d to (date received of m) as string
		on error
			try
				set d to (date sent of m) as string
			on error
				set d to ""
			end try
		end try
		try
			set a to sender of m
		on error
			set a to ""
		end try
		try
			set s to subject of m
		on error
			set s to "(utan amne)"
		end try
		-- Brödtexten är ofta det som betyder något; ämnesraden säger sällan
		-- vad som faktiskt stod. Kapas för att svaret inte ska bli ohanterligt.
		try
			set b to content of m
			if (count of b) > 4000 then set b to (text 1 thru 4000 of b)
			-- Radbrytningar skulle bryta radformatet; de blir mellanslag.
			set gamla to AppleScript's text item delimiters
			set AppleScript's text item delimiters to {linefeed, return, tab}
			set delar to text items of b
			set AppleScript's text item delimiters to " "
			set b to delar as string
			set AppleScript's text item delimiters to gamla
		on error
			set b to ""
		end try
		try
			set mid to message id of m
		on error
			set mid to ""
		end try
		return d & faltdelare & a & faltdelare & s & faltdelare & mid & faltdelare & kontonamn & faltdelare & ladnamn & faltdelare & riktning & faltdelare & b & linefeed
	end tell
end rad

-- Samma bedomning som i Swift, men gjord har sa att skrapet inte tar plats
-- i kvoten.
on varAttSpara(namn)
	set gemena to my gemener(namn)
	repeat with andelse in {".ics", ".vcf", ".p7s", ".asc", ".sig"}
		if gemena ends with (andelse as string) then return false
	end repeat
	-- Inbaddade signaturbilder heter image001.png och liknande
	if gemena starts with "image00" and (count of namn) <= 12 then return false
	return true
end varAttSpara

-- Snedstreck och kolon blir bindestreck, och ett namn som borjar med punkt
-- far ett understreck fore sig, sa att filen aldrig hamnar utanfor
-- bilagemappen eller blir dold.
on rensaNamn(t)
	set ut to ""
	repeat with c in characters of t
		set c to c as string
		if c is "/" or c is ":" then
			set ut to ut & "-"
		else
			set ut to ut & c
		end if
	end repeat
	if ut starts with "." then set ut to "_" & ut
	if ut is "" then set ut to "bilaga"
	return ut
end rensaNamn

on gemener(t)
	set ut to ""
	repeat with c in characters of t
		set c to c as string
		set i to offset of c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		if i > 0 then
			set ut to ut & (character i of "abcdefghijklmnopqrstuvwxyz")
		else
			set ut to ut & c
		end if
	end repeat
	return ut
end gemener
