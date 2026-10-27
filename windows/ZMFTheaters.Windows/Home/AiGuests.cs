namespace ZMFTheaters.Home;

/// Original fictional AI movie guests. Their replies come from an offline,
/// deterministic personality engine (keyword intents + persona phrase banks),
/// not a language model — the UI labels them "AI · scripted".
public sealed record AiPersona(string Name, string Tagline, string[] Genres, string[] Greetings, string[] BlastReactions, string[] HitReactions,
    string[] WindReactions, string[] Recommendations, string[] Opinions);

public sealed class AiGuestEngine
{
    public static readonly AiPersona[] Personas =
    {
        new("Nova", "enthusiastic movie fan", new[] { "any" },
            new[] { "Hi! Popcorn's ready — I love this seat.", "Hey hey! Best night of the week." },
            new[] { "WOW. Did you feel that?!", "That blast — chills!" }, new[] { "Oof!", "Ooh, that hit landed." },
            new[] { "I can almost feel the wind!", "Hair-in-the-wind moment!" },
            new[] { "Honestly anything with a great score — want a classic adventure next?" },
            new[] { "I'm loving this so far!", "This is such a fun pick." }),
        new("Alex", "action & science-fiction fan", new[] { "action", "science fiction", "sci-fi", "thriller" },
            new[] { "Alex here. Hope there are explosions.", "Front-row energy, let's go." },
            new[] { "Now THAT is practical-effects energy!", "Huge. Rewind that later." }, new[] { "Clean hit.", "That choreography!" },
            new[] { "Flight sequence! Love it.", "Feels like we're moving." },
            new[] { "If you liked this, try a space epic next." },
            new[] { "Solid pacing.", "The action's well shot." }),
        new("Mia", "fantasy & romance fan", new[] { "fantasy", "romance", "animation", "family" },
            new[] { "Hi! I brought tissues, just in case.", "Hello! Cozy seats tonight." },
            new[] { "Eek, that was loud!", "My heart jumped." }, new[] { "Ouch, poor them.", "Oh no!" },
            new[] { "So magical, like a breeze in a dream.", "Lovely, gentle wind." },
            new[] { "A fairy-tale romance would be perfect after this." },
            new[] { "The colours are gorgeous.", "I'm invested in these two." }),
        new("Jordan", "horror & suspense fan", new[] { "horror", "mystery", "thriller", "suspense" },
            new[] { "Jordan. Lights low, please.", "Evening. I'll be in the dark corner." },
            new[] { "...okay that got me.", "Didn't see that coming." }, new[] { "Yikes.", "That was a sharp one." },
            new[] { "Creepy wind. Something's coming.", "That breeze is unsettling." },
            new[] { "Try a slow-burn mystery next time." },
            new[] { "The tension is building nicely.", "Something's off about that character." }),
    };

    readonly Random rng;
    readonly Dictionary<string, DateTime> lastSpoke = new();
    DateTime lastRoomReaction = DateTime.MinValue;
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;
    public const string EngineLabel = "AI · scripted personality (offline)";

    public AiGuestEngine(int seed = 2026) { rng = new Random(seed); }

    public static AiPersona? Persona(string name) => Personas.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));

    string Pick(string[] options) => options[rng.Next(options.Length)];

    public string Greeting(AiPersona p) => Pick(p.Greetings);

    /// Reaction to a detected 4DX moment. Etiquette: at most one AI reaction
    /// per 20 s per room, 60 s per guest, and nothing during dialogue.
    public (string guest, string text)? React(IEnumerable<string> presentAi, string eventType, double intensity, bool dialogue)
    {
        if (dialogue || intensity < 0.45) return null;
        var now = Clock();
        if ((now - lastRoomReaction).TotalSeconds < 20) return null;
        foreach (var name in presentAi.OrderBy(_ => rng.Next()))
        {
            var p = Persona(name);
            if (p == null) continue;
            if (lastSpoke.TryGetValue(name, out var t) && (now - t).TotalSeconds < 60) continue;
            var bank = eventType switch { "Blast" => p.BlastReactions, "Hit" => p.HitReactions, "Wind" => p.WindReactions, _ => null };
            if (bank == null) return null;
            lastSpoke[name] = now; lastRoomReaction = now;
            return (p.Name, Pick(bank));
        }
        return null;
    }

    /// Reply to a chat message. Addressed guests answer; otherwise at most one
    /// guest replies to questions. During dialogue replies are whispered.
    public List<(string guest, string text)> Reply(IEnumerable<string> presentAi, string from, string message, string title, bool dialogue)
    {
        var replies = new List<(string, string)>();
        var present = presentAi.Select(Persona).Where(p => p != null).Cast<AiPersona>().ToList();
        if (present.Count == 0 || string.IsNullOrWhiteSpace(message)) return replies;
        var m = message.ToLowerInvariant();
        var addressed = present.Where(p => m.Contains(p.Name.ToLowerInvariant())).ToList();
        bool everyone = m.Contains("everyone") || m.Contains("guys") || m.Contains("all of you");
        bool question = m.Contains('?');
        var responders = addressed.Count > 0 ? addressed : everyone ? present : question ? new List<AiPersona> { present[rng.Next(present.Count)] } : new();
        foreach (var p in responders.Take(3))
        {
            string text;
            if (Has(m, "hi", "hello", "hey", "welcome")) text = $"Hi {from}! " + Pick(p.Greetings);
            else if (Has(m, "recommend", "next", "suggest", "what should")) text = Pick(p.Recommendations);
            else if (Has(m, "like", "think", "opinion", "good", "enjoy")) text = Pick(p.Opinions) + (title.Length > 0 ? $" ({title})" : "");
            else if (Has(m, "favorite", "favourite", "genre")) text = $"I'm the {p.Tagline} of the group — {string.Join(", ", p.Genres.Where(g => g != "any").DefaultIfEmpty("everything"))}.";
            else if (Has(m, "how are you", "how's it going")) text = "Great, thanks for asking! Comfy seat, good company.";
            else if (Has(m, "quiet", "shh", "shush")) text = "Sorry! Zipping it.";
            else text = question ? "Good question — I'd say keep watching and see!" : "Ha, agreed.";
            if (dialogue) text = "(whispers) " + text;
            lastSpoke[p.Name] = Clock();
            replies.Add((p.Name, text));
        }
        return replies;
    }

    static bool Has(string m, params string[] words) => words.Any(w => System.Text.RegularExpressions.Regex.IsMatch(m, $@"\b{System.Text.RegularExpressions.Regex.Escape(w)}\b"));
}
