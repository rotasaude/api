# Value Object da resposta de conversa: o que enviar de volta ao cidadão.
# kind :text | :buttons | :list | :template.
#   text/buttons/list: body (+ options [{id:, title:}] p/ buttons/list).
#   template: name (template aprovado) + params (parâmetros do componente body).
# Ver F-03.3 (envio interativo) e F-01.7 (template fora da janela 24h).
module Messaging
  class Reply
    attr_reader :kind, :body, :options, :name, :params

    def self.text(body)                  = new(kind: :text, body: body)
    def self.buttons(body:, options:)    = new(kind: :buttons, body: body, options: options)
    def self.list(body:, options:)       = new(kind: :list, body: body, options: options)
    def self.template(name:, params: []) = new(kind: :template, name: name, params: params)

    def self.from_h(hash)
      h = hash.symbolize_keys
      new(
        kind: h[:kind].to_sym,
        body: h[:body],
        options: Array(h[:options]).map { |o| o.symbolize_keys.slice(:id, :title) },
        name: h[:name],
        params: Array(h[:params])
      )
    end

    def initialize(kind:, body: nil, options: [], name: nil, params: [])
      @kind = kind
      @body = body
      @options = options.freeze
      @name = name
      @params = params.freeze
      freeze
    end

    def text?     = kind == :text
    def template? = kind == :template

    def to_h
      {
        kind: kind.to_s,
        body: body,
        options: options.map { |o| { id: o[:id], title: o[:title] } },
        name: name,
        params: params
      }
    end
  end
end
