# Formulário "Solicitar exames" dentro da página do PEC (ADR 0036; contrato
# §8 com A8/D8): HTML do servidor, escapado, sem script; o token da sessão
# curta vai num campo oculto (sem cookie de terceiro, nunca na URL).
module PecExternal
  module ExamPage
    PRIORITIES = { "routine" => "Rotina", "urgent" => "Urgente" }.freeze

    module_function

    def form(display_name:, items:, token:, nonce:, notice: nil, error: nil)
      options = items.map { |item| %(<option value="#{h(item[:code])}">#{h(item[:label])}</option>) }.join
      priorities = PRIORITIES.map { |value, label| %(<option value="#{h(value)}">#{h(label)}</option>) }.join
      Page.layout(<<~HTML, nonce: nonce)
        <h1>Solicitar exames — #{h(display_name)}</h1>
        #{notice ? %(<p class="notice">#{h(notice)}</p>) : ""}
        #{error ? %(<p class="notice">Não foi possível registrar o pedido. Código: <code>#{h(error)}</code></p>) : ""}
        <form method="post" action="/pec/exams">
          <input type="hidden" name="token" value="#{h(token)}">
          <p><label>Exame <select name="sigtap_code" required>#{options}</select></label></p>
          <p><label>Prioridade <select name="priority">#{priorities}</select></label></p>
          <p><button type="submit">Registrar pedido</button></p>
        </form>
      HTML
    end

    def h(text) = ERB::Util.html_escape(text.to_s)
  end
end
