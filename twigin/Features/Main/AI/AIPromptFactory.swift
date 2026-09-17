import Foundation

public struct AIPromptFactory {
    public static func makeRequest(forCommandIndex index: Int, selectedText: String) -> AIRequest? {
        let command: AICommand
        let prompt: String
        
        switch index {
        case 0:
            command = .translate
            prompt = """
                    Translate the following text into Chinese. Maintain the EXACT same number of paragraphs as the source text, separated by empty lines. Output ONLY the translated text:

                    \(selectedText)
                    """
            
        case 1:
            command = .summarize
            prompt = """
                    Summarize the following single paragraph into 1-2 concise sentences. 
                    Do not copy verbatim. Output plain text only:

                    \(selectedText)
                    """
            
        case 2:
            command = .keyPoints
            prompt = """
                    Extract key points from the following text as a bullet list.
                    Provide EXACTLY ONE bullet point per paragraph corresponding to the source text.
                    Format each line starting with a dash (e.g. - Key point).
                    Output ONLY the bullet list:

                    \(selectedText)
                    """
            
        case 3:
            command = .concise
            prompt = """
                    Rewrite the following text more concisely while preserving meaning.
                    Maintain the EXACT same number of paragraphs as the source text, separated by empty lines.
                    Output ONLY the rewritten text:

                    \(selectedText)
                    """
            
        default:
            command = .ask
            prompt = selectedText
        }
        
        return AIRequest(command: command, prompt: prompt)
    }
    
    public static func title(forCommandIndex index: Int) -> String {
        let titles = ["Translate", "Summarize", "Key Points", "Concise"]
        return index < titles.count ? titles[index] : "AI Action"
    }
}
