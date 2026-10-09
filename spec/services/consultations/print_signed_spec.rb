# spec/services/consultations/print_signed_spec.rb
require "rails_helper"

# ADR 0032 (spec §7; NGS2.06.05–07): o PDF que vai ao PAdES leva o rodapé
# padronizado em TODA página e não tem espaço de assinatura à mão; o adendo tem
# PDF próprio; o impresso com adendos lista o estado de cada parte. Review
# Focus 5: texto que a fonte não tem nunca derruba.
RSpec.describe "Impresso assinável" do
  before { Current.city = signature_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit("UBS Jardim das Flores") }
  let(:doctor) { signer_doctor!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana") }
  let(:footer) { Signatures::PdfFooter.new(signer_name: "MARIA ≥ SOUZA", signer_cpf: SignatureHelpers::DOCTOR_CPF, signed_at: Time.utc(2026, 10, 8, 13, 45), simulated: false) }

  def pages(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map { |page| page.text.gsub(/\s+/, " ") }

  it "rodapé NGS2 em toda página, sem assinatura à mão, com texto longo e caracteres fora da fonte" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, plan: "linha de plano " * 1_300)
    texts = pages(Consultations::Print.call(consultation, footer: footer, addenda: false))
    expect(texts.size).to be > 1
    texts.each do |text|
      expect(text).to include("assinado digitalmente por MARIA ? SOUZA", "***.982.247-**", "08/10/2026 13:45 UTC", "AD-RB",
                              "validar.iti.gov.br")
    end
    expect(texts.join).not_to include("Assinatura e carimbo")
  end

  it "addenda: false deixa o adendo de fora; o PDF do adendo é só dele" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido",
                                               text: "Texto do ADENDO").payload[:addendum]
    expect(pages(Consultations::Print.call(consultation.reload, footer: footer, addenda: false)).join).not_to include("Texto do ADENDO")
    text = pages(Consultations::Print.addendum(addendum, footer: footer)).join("\n")
    expect(text).to include("Adendo à consulta de", "Mariana", "exame adicional pedido", "Texto do ADENDO",
                            "assinado digitalmente por", "UBS Jardim das Flores")
    expect(text).not_to include("Refere sede e poliúria")
  end

  it "seção de assinaturas: espaço à mão só quando alguma parte não é digital" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    report = Struct.new(:lines, :hand_signature?).new([ "Consulta: assinada digitalmente — válida" ], false)
    text = pages(Consultations::Print.call(consultation, report: report)).join
    expect(text).to include("Assinaturas", "Consulta: assinada digitalmente")
    expect(text).not_to include("Assinatura e carimbo")
    report = Struct.new(:lines, :hand_signature?).new([ "Adendo de 08/10/2026: sem assinatura digital" ], true)
    expect(pages(Consultations::Print.call(consultation, report: report)).join).to include("Assinatura e carimbo")
  end

  it "rodapé simulado leva o aviso em toda página; o real não" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, plan: "linha de plano " * 1_300)
    simulated = footer.with(simulated: true)
    texts = pages(Consultations::Print.call(consultation, footer: simulated, addenda: false))
    expect(texts.size).to be > 1
    texts.each { |text| expect(text).to include("SIMULADA — SEM VALIDADE JURÍDICA", "assinado digitalmente por") }
    expect(simulated.text.downcase).to include("simulada — sem validade jurídica")
    real = pages(Consultations::Print.call(consultation, footer: footer, addenda: false)).join
    expect(real.downcase).not_to include("simulada")
    expect(footer.text).to eq("Documento assinado digitalmente por MARIA ≥ SOUZA (CPF ***.982.247-**) em 08/10/2026 13:45 UTC — " \
                              "ICP-Brasil, política AD-RB. Verifique em https://validar.iti.gov.br")
  end

  it "PDF do adendo com mudanças estruturadas (item_changes) mostra as mudanças" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "conduta e exame acrescentados",
                                               text: "x", changes: { "conducts" => [ 9 ],
                                                                     "exam_requests" => [ { "sigtap_code" => "0202010317" } ] })
                                         .payload[:addendum]
    expect(addendum.item_changes).to be_present
    text = pages(Consultations::Print.addendum(addendum, footer: footer)).join("\n")
    expect(text).to include("Mudanças estruturadas", "Condutas (lista final)", Ledi::ConsultationMapping.conduct_label(9),
                            "Exames solicitados (lista final)", "0202010317")
    cancelled = Consultations::AddAddendum.call(consultation: consultation.reload, by: doctor, reason: "cancelar todos os exames",
                                                text: "x", changes: { "exam_requests" => [] }).payload[:addendum]
    expect(pages(Consultations::Print.addendum(cancelled, footer: footer)).join).to include("todos cancelados")
  end

  it "Review Focus 5: emoji, ≥, CRLF, 20.000 caracteres e certificado acentuado geram o PDF, com rodapé em todas as páginas" do
    head = "Dor 😀 ≥ 3\r\nlinha dois "
    odd = head + ("á" * (20_000 - head.length))
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, plan: odd)
    accented = footer.with(signer_name: "JOÃO DA CONCEIÇÃO 😀")
    texts = pages(Consultations::Print.call(consultation, footer: accented, addenda: false))
    expect(texts.size).to be > 1
    texts.each { |text| expect(text).to include("assinado digitalmente por JOÃO DA CONCEIÇÃO ?", "validar.iti.gov.br") }
    expect(texts.join).to include("Dor ? ? 3")
  end
end
