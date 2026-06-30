# Mapeia o answer_type de um Protocols::Step para o elemento WhatsApp adequado.
# Ver F-03.3. Limites do WhatsApp Cloud: botão título 20, row título 24,
# máx 3 botões, máx 10 rows.
module Whatsapp
  class QuestionElement
    BUTTON_TITLE = 20
    ROW_TITLE = 24
    MAX_BUTTONS = 3
    MAX_ROWS = 10

    def self.for(step, body:)
      new(step, body).call
    end

    def initialize(step, body)
      @step = step
      @body = body
    end

    def call
      case @step.answer_type
      when :boolean
        Messaging::Reply.buttons(body: @body, options: [
          { id: "true",  title: I18n.t("whatsapp.btn_yes") },
          { id: "false", title: I18n.t("whatsapp.btn_no") }
        ])
      when :enum
        opts = Array(@step.options)
        if opts.size <= MAX_BUTTONS
          Messaging::Reply.buttons(body: @body, options: opts.map { |o| option(o, BUTTON_TITLE) })
        elsif opts.size <= MAX_ROWS
          Messaging::Reply.list(body: @body, options: opts.map { |o| option(o, ROW_TITLE) })
        else
          Messaging::Reply.text(@body)
        end
      else
        Messaging::Reply.text(@body)
      end
    end

    private

    def option(value, limit)
      title = value.length > limit ? "#{value[0, limit - 1]}…" : value
      { id: value, title: title }
    end
  end
end
