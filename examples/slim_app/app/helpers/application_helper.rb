# frozen_string_literal: true

module ApplicationHelper
  def link_to(text, url)
    "<a href=\"#{url}\">#{text}</a>"
  end

  def pluralize(count, singular, plural = nil)
    word = count == 1 ? singular : (plural || "#{singular}s")
    "#{count} #{word}"
  end

  def time_ago_in_words(time)
    seconds = Time.now - time
    case seconds
    when 0..59 then "just now"
    when 60..3599 then "#{(seconds / 60).to_i} minutes ago"
    when 3600..86_399 then "#{(seconds / 3600).to_i} hours ago"
    else "#{(seconds / 86_400).to_i} days ago"
    end
  end

  def current_user
    User.new(name: "Alice", email: "alice@example.com", role: "admin")
  end
end
