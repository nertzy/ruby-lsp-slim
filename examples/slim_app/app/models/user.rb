# frozen_string_literal: true

class User
  attr_accessor :name, :email, :role, :created_at

  def initialize(name:, email:, role: "member", created_at: Time.now)
    @name = name
    @email = email
    @role = role
    @created_at = created_at
  end

  def admin?
    role == "admin"
  end

  def display_name
    "#{name} (#{email})"
  end

  def self.all
    [
      new(name: "Alice", email: "alice@example.com", role: "admin"),
      new(name: "Bob", email: "bob@example.com"),
      new(name: "Charlie", email: "charlie@example.com")
    ]
  end
end
