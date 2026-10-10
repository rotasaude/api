# spec/services/clinical_documents/pdf_spec.rb
require "rails_helper"
require "pdf/reader"

# Spec §6: PDF por tipo — cabeçalho (unidade, CNES, cidade), corpo do tipo,
# profissional (conselho, CBO), QR code e código curto em toda via; papel com
# espaço para assinatura; antimicrobiano em 2 vias; digital com o rodapé NGS2.
RSpec.describe ClinicalDocuments::Pdf do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release!; city_profile! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text)
  def issue!(kind, content, by: doctor) = ClinicalDocuments::Issue.call(kind: kind, content: content, by: by, consultation: consultation).payload.fetch(:document)

  it "atestado: título, paciente, dias, CID com a autorização, profissional, código e endereço de conferência" do
    document = issue!("sick_note", { "type" => "leave", "days" => 3, "cid10" => { "code" => "I10" }, "cid_authorized" => true })
    pages = text_of(described_class.call(document))
    text = pages.join("\n")
    expect(text).to include("ATESTADO", "Maria Aparecida da Silva", "3 dia(s)", "I10", "autorização expressa do paciente",
                            ClinicalDocuments::Codes.display(document.short_code), "/v/#{document.verification_token}",
                            "Assinatura e carimbo", doctor.professional.professional_name, "CBO 225125")
  end

  it "receita com antimicrobiano: duas vias, cada uma com o código; validade de 10 dias" do
    import_test_catalog!
    document = issue!("prescription", { "items" => [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21,
                                                       "quantity_unit" => "cápsula", "route" => "oral",
                                                       "dosage_instructions" => "1 cápsula de 8/8h por 7 dias" } ] })
    pages = text_of(described_class.call(document))
    code = ClinicalDocuments::Codes.display(document.short_code)
    expect(pages.size).to eq(2)
    expect(pages[0]).to include("1ª via — farmácia", code, "AMOXICILINA 500 MG", "21 cápsula", "Validade")
    expect(pages[1]).to include("2ª via — paciente", code)
  end

  it "receita cheia (Review Focus 5): 20 itens, emoji, ≥, \\r\\n e posologia longa; o código em toda via" do
    import_test_catalog!
    items = Array.new(20) do |i|
      { "free_text" => "Chá de camomila #{i} 🌼", "quantity" => 1, "quantity_unit" => "caixa", "route" => "oral",
        "dosage_instructions" => "Tomar ≥ 1 sachê\r\nà noite. #{'x' * 440}" }
    end
    document = issue!("prescription", { "items" => items })
    pages = text_of(described_class.call(document))
    expect(pages.size).to be >= 2
    expect(pages.join).to include("Chá de camomila 19 ?", ClinicalDocuments::Codes.display(document.short_code))
  end

  it "declaração da recepção: matrícula de quem emite; enfermagem: protocolo, CNPJ e Coren" do
    declaration = ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: { "issuer_registration" => "4471" },
                                                by: verifier!, attendance: consultation.attendance).payload[:document]
    text = text_of(described_class.call(declaration)).join
    expect(text).to include("DECLARAÇÃO DE COMPARECIMENTO", "Emitido pela recepção", "Matrícula: 4471")
    # Revisão final I4: o papel vai ao cidadão; o e-mail de login da recepção nunca.
    email = declaration.author_user.email_address
    expect([ text, text.gsub(/\s+/, "") ]).to all(satisfy { |t| !t.include?(email) && !t.include?(email.split("@").first) })

    import_test_catalog!
    city_cnpj!
    nurse = nurse!(unit)
    params = { "title" => "Saúde da mulher", "number" => "PE-01", "year" => 2026, "valid_from" => (Time.zone.today - 1).iso8601,
               "items" => [ { "catalog_item_id" => catalog_item(267_503).id } ] }
    version = NursingProtocols::Save.create(params: params, by: municipal_admin!, catalog: { catalog_item(267_503).id => catalog_item(267_503) })
                                    .payload[:protocol].current_version
    nursing = finalized_consultation!(unit: unit, doctor: nurse, citizen: verified_citizen!(2, full_name: "Rita Souza"))
    document = ClinicalDocuments::Issue.call(kind: "prescription", by: nurse, consultation: nursing,
                                             content: { "nursing_protocol" => { "version_id" => version.id },
                                                        "items" => [ { "catalog_item" => { "id" => catalog_item(267_503).id }, "quantity" => 30,
                                                                       "quantity_unit" => "comprimido", "route" => "oral",
                                                                       "dosage_instructions" => "1 comprimido ao dia" } ] }).payload[:document]
    text = text_of(described_class.call(document)).join
    expect(text).to include("Saúde da mulher", "PE-01/2026", "76.001.234/0001-15", "COREN")
  end

  it "requisição de exames lista os exames; digital leva o rodapé NGS2 em toda página e não o espaço à mão" do
    document = issue!("exam_requisition", {})
    footer = Signatures::PdfFooter.new(signer_name: "MÉDICA DE TESTE", signer_cpf: "52998224725", signed_at: Time.current, simulated: true)
    pages = text_of(described_class.call(document, footer: footer))
    expect(pages.join).to include("REQUISIÇÃO DE EXAMES", "0202010503", "DOSAGEM DE HEMOGLOBINA GLICOSILADA")
    expect(pages).to all(include("Documento assinado digitalmente por"))
    expect(pages.join).not_to include("Assinatura e carimbo")
  end

  it "cancelado não imprime" do
    document = issue!("sick_note", { "type" => "leave", "days" => 1 })
    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current, cancelled_by_user_id: doctor.id)
    expect { described_class.call(document) }.to raise_error(described_class::NotPrintable)
  end

  it "QR: um quadrado por módulo escuro, dentro da área pedida" do
    url = "https://curitiba.rotasaude.app/v/#{ClinicalDocuments::Codes.token}"
    modules = ClinicalDocuments::Qr.matrix(url)
    pdf = instance_double(Prawn::Document, fill_color: nil)
    calls = []
    allow(pdf).to receive(:fill_rectangle) { |point, w, h| calls << [ point, w, h ] }
    ClinicalDocuments::Qr.draw(pdf, url, at: [ 100, 200 ], size: 84)
    expect(calls.size).to eq(modules.flatten.count(true))
    expect(calls.map { |(x, _y), _w, _h| x }.min).to be >= 100
    expect(calls.map { |(x, _y), w, _h| x + w }.max).to be <= 184.0001
  end

  # Review Focus (controlador): o pior caso junto — antimicrobiano (2 vias),
  # 20 itens, posologia de 500 caracteres com emoji, "≥" e \r\n, nome social
  # com acento. O PDF sai, o que a fonte não tem vira "?", e cada via traz o
  # rótulo, o código curto e o endereço de conferência.
  it "receita antimicrobiana cheia com nome social acentuado: duas vias, cada uma com código e conferência" do
    import_test_catalog!
    citizen = verified_citizen!(3, social_name: "Joséphine Araújo")
    big = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    long = "Tomar ≥ 1 sachê 🌙\r\nà noite. ".then { |head| head + ("y" * (500 - head.gsub("\r\n", "\n").size)) }
    expect(long.gsub("\r\n", "\n").size).to eq(500)
    items = [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21, "quantity_unit" => "cápsula",
                "route" => "oral", "dosage_instructions" => long } ] +
            Array.new(19) { |i| { "free_text" => "Chá de camomila #{i} 🌼", "quantity" => 1, "quantity_unit" => "caixa",
                                  "route" => "oral", "dosage_instructions" => long } }
    document = ClinicalDocuments::Issue.call(kind: "prescription", content: { "items" => items }, by: doctor, consultation: big)
                                       .payload.fetch(:document)
    pages = text_of(described_class.call(document))
    text = pages.join("\n")
    code = ClinicalDocuments::Codes.display(document.short_code)
    first = pages.index { |page| page.include?("1ª via — farmácia") }
    second = pages.index { |page| page.include?("2ª via — paciente") }
    expect([ first, second ]).to all(be_an(Integer))
    expect(pages[first...second].join).to include(code, "/v/#{document.verification_token}", "Chá de camomila 18 ?")
    expect(pages[second..].join).to include(code, "/v/#{document.verification_token}", "Chá de camomila 18 ?")
    expect(text.scan(code).size).to eq(2)
    expect(text).to include("Joséphine Araújo", "Tomar ? 1 sachê ?", "AMOXICILINA 500 MG")
    expect(text).not_to include("\r")
  end

  it "item sem forma farmacêutica: imprime a descrição gravada, sem inventar forma" do
    import_test_catalog!
    losartana = catalog_item(268_856)
    losartana.update_columns(dosage_form: nil)
    document = issue!("prescription", { "items" => [ { "catalog_item" => { "id" => losartana.id }, "quantity" => 30,
                                                       "quantity_unit" => "comprimido", "route" => "oral",
                                                       "dosage_instructions" => "1 comprimido pela manhã" } ] })
    text = text_of(described_class.call(document)).join
    expect(text).to include("1. #{losartana.label} — 30 comprimido")
    expect(text).not_to include("COMPRIMIDO")
  end

  it "atestado de acompanhante: data do acompanhamento = start_on; sem start_on, a data da emissão" do
    base = { "type" => "companion", "companion_name" => "João Souza", "companion_kinship" => "filho",
             "companion_reason" => "clt_473_xi" }
    start_on = Time.zone.today - 3
    with_start = text_of(described_class.call(issue!("sick_note", base.merge("start_on" => start_on.iso8601)))).join
    expect(with_start).to include("João Souza (filho)", "em #{start_on.strftime('%d/%m/%Y')}", "CLT, art. 473, XI")
    without = issue!("sick_note", base)
    expect(text_of(described_class.call(without)).join).to include("em #{without.issued_at.in_time_zone.strftime('%d/%m/%Y')}")
  end
  describe "texto dos itens da receita e da declaração (prova no navegador)" do
    def prescription_text(item)
      import_test_catalog!
      base = { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30,
               "quantity_unit" => "comprimido", "route" => "oral" }
      text_of(described_class.call(issue!("prescription", { "items" => [ base.merge(item) ] }))).join.gsub(/\s+/, " ")
    end

    it "item não contínuo não imprime nada sobre uso contínuo (nunca 'false')" do
      text = prescription_text("dosage_instructions" => "Tomar 1 comprimido ao dia", "duration_days" => 30, "continuous" => false)
      expect(text).to include("Uso: via oral. Tomar 1 comprimido ao dia. por 30 dia(s)")
      expect(text).not_to include("false")
      expect(text).not_to include("contínuo")
    end

    it "item contínuo mantém o texto de uso contínuo" do
      text = prescription_text("dosage_instructions" => "Tomar 1 comprimido ao dia", "continuous" => true)
      expect(text).to include("Tomar 1 comprimido ao dia. uso contínuo")
    end

    it "posologia que já termina em pontuação não ganha ponto duplo" do
      text = prescription_text("dosage_instructions" => "Tomar 1 comprimido pela manha.", "duration_days" => 30)
      expect(text).to include("Tomar 1 comprimido pela manha. por 30 dia(s)")
      expect(text).not_to include("..")
      expect(prescription_text("dosage_instructions" => "Tomar se tiver dor!", "duration_days" => 5))
        .to include("Tomar se tiver dor! por 5 dia(s)")
    end

    it "declaração sem saída: 'a partir das HH:MM'; com saída: 'das X às Y'; período inalterado" do
      open_text = text_of(described_class.call(issue!("attendance_declaration", { "arrived_at" => "19:14", "left_at" => nil }))).join.gsub(/\s+/, " ")
      expect(open_text).to include("a partir das 19:14.")
      expect(open_text).not_to include(", das 19:14.")

      closed_text = text_of(described_class.call(issue!("attendance_declaration", { "arrived_at" => "08:00", "left_at" => "09:30" }))).join.gsub(/\s+/, " ")
      expect(closed_text).to include("das 08:00 às 09:30.")

      period_text = text_of(described_class.call(issue!("attendance_declaration", { "period" => "morning" }))).join.gsub(/\s+/, " ")
      expect(period_text).to include(described_class::PERIODS.fetch("morning"))
    end
  end
end
