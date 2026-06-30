# Value Object da resposta de conversa: o que enviar de volta ao cidadão.
# kind :text | :buttons | :list; options = [{id:, title:}] (vazio p/ text).
# Ver F-03.3 (camada de envio interativo do WhatsApp).
module Messaging
  class Reply
    attr_reader :kind, :body, :options

    def self.text(body)               = new(kind: :text, body: body)
    def self.buttons(body:, options:) = new(kind: :buttons, body: body, options: options)
    def self.list(body:, options:)    = new(kind: :list, body: body, options: options)

    def self.from_h(hash)
      h = hash.symbolize_keys
      new(
        kind: h[:kind].to_sym,
        body: h[:body],
        options: Array(h[:options]).map { |o| o.symbolize_keys.slice(:id, :title) }
      )
    end

    def initialize(kind:, body:, options: [])
      @kind = kind
      @body = body
      @options = options.freeze
      freeze
    end

    def text? = kind == :text

    def to_h
      { kind: kind.to_s, body: body, options: options.map { |o| { id: o[:id], title: o[:title] } } }
    end
  end
end
