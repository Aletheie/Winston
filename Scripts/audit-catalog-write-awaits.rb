#!/usr/bin/env ruby
# frozen_string_literal: true

# Conservative source audit for C1. It reports async Swift functions that appear
# to mutate SwiftData-backed catalog state and then suspend before a synchronous
# save/commit boundary. Findings require review because this is deliberately a
# lightweight lexical check rather than a Swift compiler plug-in.

root = File.expand_path(ARGV.fetch(0, File.join(__dir__, "..")))
source_root = File.join(root, "Winston")

unless Dir.exist?(source_root)
  warn "Winston source directory not found at #{source_root}"
  exit 2
end

def masked_swift(source)
  output = source.dup
  state = :code
  block_depth = 0
  index = 0

  while index < source.length
    current = source[index]
    following = source[index + 1]

    case state
    when :code
      if current == "/" && following == "/"
        output[index, 2] = "  "
        index += 2
        state = :line_comment
      elsif current == "/" && following == "*"
        output[index, 2] = "  "
        index += 2
        block_depth = 1
        state = :block_comment
      elsif source[index, 3] == "\"\"\""
        output[index, 3] = "   "
        index += 3
        state = :multiline_string
      elsif current == "\""
        output[index] = " "
        index += 1
        state = :string
      elsif current == "'"
        output[index] = " "
        index += 1
        state = :character
      else
        index += 1
      end
    when :line_comment
      if current == "\n"
        state = :code
      else
        output[index] = " "
      end
      index += 1
    when :block_comment
      if current == "/" && following == "*"
        output[index, 2] = "  "
        block_depth += 1
        index += 2
      elsif current == "*" && following == "/"
        output[index, 2] = "  "
        block_depth -= 1
        index += 2
        state = :code if block_depth.zero?
      else
        output[index] = " " unless current == "\n"
        index += 1
      end
    when :multiline_string
      if source[index, 3] == "\"\"\""
        output[index, 3] = "   "
        index += 3
        state = :code
      else
        output[index] = " " unless current == "\n"
        index += 1
      end
    when :string, :character
      terminator = state == :string ? "\"" : "'"
      if current == "\\"
        output[index] = " "
        output[index + 1] = " " if following && following != "\n"
        index += 2
      elsif current == terminator
        output[index] = " "
        index += 1
        state = :code
      else
        output[index] = " " unless current == "\n"
        index += 1
      end
    end
  end

  output
end

def matching_delimiter(source, opening, opening_character, closing_character)
  depth = 0
  index = opening
  while index < source.length
    character = source[index]
    depth += 1 if character == opening_character
    depth -= 1 if character == closing_character
    return index if depth.zero?
    index += 1
  end
  nil
end

def matching_brace(source, opening)
  matching_delimiter(source, opening, "{", "}")
end

def line_number(source, offset)
  source[0...offset].count("\n") + 1
end

context_mutation = /
  \b(?:self\s*\.\s*)?(?:modelContext|context|writeContext)\s*\.\s*(?:insert|delete)\s*\(
/x

model_identifier = /
  \b(?:
    [A-Za-z_]\w*
    (?:Book|Work|Asset|Collection|Notice|Wishlist|Highlight|ReadingEvent|Plugin|Edition)
    [A-Za-z_0-9]*
    |
    book|work|asset|collection|notice|item|highlight|event|edition|
    winner|loser|survivor
  )
  \s*\.\s*[A-Za-z_]\w*\s*
  (?:
    (?<![=!<>])=(?!=)
    |
    \.(?:append|remove|removeAll|insert)\s*\(
  )
/x

common_model_mutation = /
  \b(?:book|work|asset|collection|notice|item|highlight|event|edition|
      liveBook|liveAsset|restoredBook|winner|loser|survivor|removedBook)
  \s*\.\s*
  (?:set[A-Z]\w*|selectCoverOwner|apply[A-Z]\w*)\s*\(
/x

save_boundary = /
  (?:
    \b(?:self\s*\.\s*)?(?:modelContext|context|writeContext)\s*\.\s*(?:save|rollback)\s*\(
    |
    \b(?:mutations|writer|resolvedMutations|writeCoordinator)\s*\.\s*
      (?:commit|commitPrepared)\s*\(
  )
/x

coordinator_call = /
  \b(?:mutations|writer|resolvedMutations|writeCoordinator)\s*\.\s*
  (?:commit|commitPrepared|commitFileMutation|commitStagedFiles)\s*\(
/x

def coordinator_owned_ranges(body, coordinator_call)
  ranges = []
  closure_names = []

  body.to_enum(:scan, coordinator_call).each do
    call_match = Regexp.last_match
    opening = body.index("(", call_match.begin(0))
    next unless opening

    closing = matching_delimiter(body, opening, "(", ")")
    next unless closing

    ranges << (opening..closing)
    call_source = body[opening..closing]
    call_source.scan(/\b(?:applying|revertingOnFailure)\s*:\s*([A-Za-z_]\w*)/) do |match|
      closure_names << match.first
    end

    trailing = closing + 1
    trailing += 1 while trailing < body.length && body[trailing].match?(/\s/)
    if body[trailing] == "{"
      trailing_close = matching_brace(body, trailing)
      ranges << (trailing..trailing_close) if trailing_close
    end
  end

  closure_names.uniq.each do |name|
    definition = body.match(
      /\b(?:let|var)\s+#{Regexp.escape(name)}\b[^=]{0,300}=\s*\{/m
    )
    next unless definition

    opening = body.index("{", definition.begin(0))
    closing = matching_brace(body, opening) if opening
    ranges << (opening..closing) if opening && closing
  end

  ranges
end

findings = []

Dir.glob(File.join(source_root, "**", "*.swift")).sort.each do |path|
  source = File.read(path)
  masked = masked_swift(source)
  search_offset = 0

  while (function_match = masked.match(/\bfunc\s+(`[^`]+`|[A-Za-z_]\w*)/, search_offset))
    opening = masked.index("{", function_match.end(0))
    break unless opening

    header = masked[function_match.begin(0)...opening]
    search_offset = function_match.end(0)
    next unless header.match?(/\basync\b/)

    closing = matching_brace(masked, opening)
    next unless closing

    body = masked[(opening + 1)...closing]
    owned_ranges = coordinator_owned_ranges(body, coordinator_call)
    mutations = []
    [context_mutation, model_identifier, common_model_mutation].each do |pattern|
      body.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        next if owned_ranges.any? { |range| range.cover?(match.begin(0)) }

        mutations << [match.begin(0), match[0].gsub(/\s+/, " ").strip]
      end
    end
    mutations.sort_by!(&:first)

    body.to_enum(:scan, /\bawait\b/).each do
      await_match = Regexp.last_match
      mutation = mutations.reverse.find { |offset, _| offset < await_match.begin(0) }
      next unless mutation

      between = body[mutation[0]...await_match.begin(0)]
      next if between.match?(save_boundary)

      absolute_mutation = opening + 1 + mutation[0]
      absolute_await = opening + 1 + await_match.begin(0)
      findings << {
        path: path.delete_prefix("#{root}/"),
        function: function_match[1],
        function_line: line_number(source, function_match.begin(0)),
        mutation_line: line_number(source, absolute_mutation),
        await_line: line_number(source, absolute_await),
        mutation: mutation[1],
      }
    end

    search_offset = closing + 1
  end
end

if findings.empty?
  puts "Catalog write/await audit: no candidates found."
  exit 0
end

puts "Catalog write/await audit: #{findings.length} candidate(s) require review:"
findings.each do |finding|
  puts [
    "#{finding[:path]}:#{finding[:function_line]}",
    "func #{finding[:function]}",
    "mutation line #{finding[:mutation_line]} (#{finding[:mutation]})",
    "await line #{finding[:await_line]}",
  ].join(" | ")
end
exit 1
