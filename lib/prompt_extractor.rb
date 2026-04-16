module PromptExtractor
  Result = Struct.new(:prompt, :system_prompt, keyword_init: true) do
    def valid?
      !prompt.to_s.empty?
    end
  end

  def self.from_anthropic(body)
    messages = body["messages"]
    return nil unless messages.is_a?(Array) && !messages.empty?

    Result.new(
      prompt: extract_user_text_anthropic(messages),
      system_prompt: extract_system_anthropic(body["system"]),
    )
  end

  def self.from_openai(body)
    messages = body["messages"]
    return nil unless messages.is_a?(Array) && !messages.empty?

    system_parts = []
    user_parts = []
    messages.each do |m|
      case m["role"]
      when "system" then system_parts << m["content"].to_s
      when "user"   then user_parts << m["content"].to_s
      end
    end

    Result.new(
      prompt: user_parts.join("\n\n"),
      system_prompt: system_parts.any? ? system_parts.join("\n\n") : nil,
    )
  end

  def self.extract_system_anthropic(sys)
    return nil if sys.nil?
    return sys if sys.is_a?(String)
    return nil unless sys.is_a?(Array)

    real = sys.select do |b|
      b.is_a?(Hash) && b["type"] == "text" &&
        !b["text"].to_s.include?("x-anthropic-billing-header")
    end
    return nil if real.empty?

    real.map { |b| b["text"] }.join("\n\n")
  end

  def self.extract_user_text_anthropic(messages)
    parts = messages.select { |m| m["role"] == "user" }.map do |m|
      content = m["content"]
      if content.is_a?(Array)
        content.select { |b| b.is_a?(Hash) && b["type"] == "text" }
               .map { |b| b["text"] }.join("\n")
      else
        content.to_s
      end
    end
    parts.join("\n\n")
  end
end
