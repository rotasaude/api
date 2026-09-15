require "rails_helper"

RSpec.describe AlertMailer, type: :mailer do
  let(:triage_id) { SecureRandom.uuid }
  # 13:30 UTC == 10:30 em America/Sao_Paulo (UTC-3) -- prova que a view
  # exibe no horário de Brasília independente do offset da string recebida.
  let(:occurred_at) { "2026-09-15T13:30:00Z" }

  def build_mail
    described_class.urgent(to: "secretaria@cidade.gov.br", triage_id: triage_id, tier: "alta",
                           priority: 1, occurred_at: occurred_at)
  end

  # B1 (fix round 1): antes não havia view nenhuma em app/views/alert_mailer,
  # então toda entrega real levantava ActionView::MissingTemplate. Este spec
  # renderiza de verdade (não stub) -- se a view voltar a desaparecer ou o
  # layout quebrar, este teste (não só o de DispatchMunicipalityAlertJob, que
  # poderia mascarar com um stub) fica vermelho.
  it "renderiza os text e html parts de verdade com tier/prioridade/id/data em America/Sao_Paulo" do
    mail = build_mail

    expect(mail.to).to eq([ "secretaria@cidade.gov.br" ])
    expect(mail.subject).to include("alta")

    [ mail.text_part.body.decoded, mail.html_part.body.decoded ].each do |body|
      expect(body).to include("Tier: alta")
      expect(body).to include("Prioridade: 1")
      expect(body).to include("ID da triagem: #{triage_id}")
      expect(body).to include("15/09/2026 10:30")
    end
  end

  # O mailer só recebe triage_id/tier/priority/occurred_at (nenhum dado do
  # cidadão -- telefone, respostas, etc. -- chega até aqui). Este teste é
  # defensivo: guarda contra alguém adicionar um campo de cidadão no futuro
  # sem querer.
  it "não vaza dado do cidadão (o mailer não recebe nenhum)" do
    mail = build_mail

    [ mail.text_part.body.decoded, mail.html_part.body.decoded ].each do |body|
      expect(body).not_to match(/telefone|phone|resposta|answer|consentimento|consent|\+55\d/i)
    end
  end
end
