require "rails_helper"
require "pdf/reader"

# Spec §6; P&R RDC 1.000 (itens 7, 67); Desvio 14: título "Receita de
# Controle Especial", número SNCR em destaque, 1ª via farmácia / 2ª via
# paciente, emitente e paciente com endereço, rodapé Anvisa, faixa de
# simulado em toda página. Review Focus 5: receita cheia com emoji.
RSpec.describe "PDF da receita controlada" do
  before do
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:fluoxetina) { controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }

  def rce_item(item = fluoxetina, dosage: "1 cápsula pela manhã")
    { "catalog_item" => { "id" => item.id }, "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
      "dosage_instructions" => dosage, "duration_days" => 60 }
  end

  def issue!(content)
    ClinicalDocuments::Issue.call(kind: "prescription", by: doctor, consultation: consultation, content: content).payload.fetch(:document)
  end

  def pages(document) = PDF::Reader.new(StringIO.new(ClinicalDocuments::Pdf.call(document))).pages.map(&:text)

  context "com o SNCR simulado" do
    before { controlled_city!(mock: true) }

    it "RCE digital simulada: título, número em cada via, contatos, rodapé Anvisa, faixa em toda página" do
      linked_certificate!(doctor)
      sncr_stock!(doctor, kind: "rce", count: 1)
      document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
      texts = pages(document)
      expect(texts.size).to eq(2)
      texts.each_with_index do |text, index|
        expect(text).to include("RECEITA DE CONTROLE ESPECIAL — ELETRÔNICA", "Nº 2610.1-41.0000001",
                                index.zero? ? "1ª via — farmácia" : "2ª via — paciente",
                                "NUMERAÇÃO SIMULADA — SEM VALIDADE", "sncr.anvisa.gov.br", "validar.iti.gov.br",
                                "Rua das Araucárias, 120 — Centro — Curitiba/PR — CEP 80010-000", "Telefone: (41) 99999-0000",
                                "CPF: #{consultation.patient.cpf.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4')}",
                                "Esta prescrição pode ser verificada em:")
      end
    end

    it "RET digital: título de antimicrobiano eletrônica, validade de 10 dias" do
      linked_certificate!(doctor)
      sncr_stock!(doctor, kind: "ret", count: 1)
      document = issue!("items" => [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21, "quantity_unit" => "cápsula",
                                       "route" => "oral", "dosage_instructions" => "1 cápsula de 8 em 8 horas", "duration_days" => 7 } ])
      text = pages(document).join("\n")
      expect(text).to include("RECEITA DE ANTIMICROBIANO — ELETRÔNICA", "Nº 2610.2-41.0000001",
                              "Validade: até #{(Time.zone.today + 10).strftime('%d/%m/%Y')}")
      expect(text).not_to include("Endereço: ____") # FW7: a RET digital sem identificação não pede endereço
    end

    it "RET de papel sem identificação: a linha de endereço em branco continua (FW7)" do
      document = issue!("items" => [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21, "quantity_unit" => "cápsula",
                                       "route" => "oral", "dosage_instructions" => "1 cápsula de 8 em 8 horas", "duration_days" => 7 } ])
      expect(document.issue_mode).to eq("paper")
      expect(pages(document).join("\n")).to include("ANTIMICROBIANO", "Endereço: ____")
    end

    it "RCE de papel: sem número nem faixa, endereços impressos, assinatura à mão, 2 vias" do
      document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
      texts = pages(document)
      expect(texts.size).to eq(2)
      expect(texts.first).to include("RECEITA DE CONTROLE ESPECIAL", "CPF: #{consultation.patient.cpf[0, 3]}.", "Assinatura e carimbo",
                                     "Rua das Araucárias")
      expect(texts.join).not_to include("ELETRÔNICA", "Nº 2610", "NUMERAÇÃO SIMULADA")
    end

    it "RCE que voltou ao papel: o content ainda guarda o sncr, mas o PDF não imprime número nem faixa" do
      linked_certificate!(doctor)
      sncr_stock!(doctor, kind: "rce", count: 1)
      document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
      Signatures::ReturnToPaper.call(request_id: document.signature_request.id, by: doctor, reason: "Paciente pediu o papel agora")
      document.reload
      expect(document.content_data["sncr"]).to be_present
      text = pages(document).join("\n")
      expect(text).to include("RECEITA DE CONTROLE ESPECIAL", "Assinatura e carimbo")
      expect(text).not_to include("2610.1-41", "NUMERAÇÃO SIMULADA", "ELETRÔNICA", "sncr.anvisa.gov.br")
    end

    it "receita comum não ganha a linha de endereço do emitente" do
      document = issue!("items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                                       "route" => "oral", "dosage_instructions" => "1 ao dia", "duration_days" => 30 } ])
      text = pages(document).join("\n")
      expect(text).to include("RECEITUÁRIO")
      expect(text).not_to include("Telefone:", "Endereço: Rua")
    end

    it "RCE cheia: 3 C1 + 1 C5, posologia longa com emoji, endereço com emoji (Review Focus 5)" do
      linked_certificate!(doctor)
      sncr_stock!(doctor, kind: "rce", count: 1)
      items = [ fluoxetina, controlled_item!(code: 9_900_006, ingredient: "SERTRALINA", list: "C1"),
                controlled_item!(code: 9_900_007, ingredient: "AMITRIPTILINA", list: "C1"),
                controlled_item!(code: 9_900_009, ingredient: "NANDROLONA", list: "C5") ]
                .map { |item| rce_item(item, dosage: "Tomar 💊 ≥ 1 vez ao dia\r\n#{'x' * 470}") }
      address = ControlledPrescriptionHelpers::ADDRESS.merge("street" => "Rua São João 🌳")
      document = issue!("items" => items, "patient_identification" => patient_identification("address" => address))
      texts = pages(document)
      expect(texts.size).to be >= 2
      expect(texts).to all(include("NUMERAÇÃO SIMULADA — SEM VALIDADE"))
      expect(texts.join).to include("Rua São João ?", "Nº 2610.1-41.0000001", "2ª via — paciente")
    end
  end

  describe "CNPJ do rodapé Anvisa: o do modo do número, não o modo corrente da cidade (FW4)" do
    let(:real_cnpj) { "11444777000161" }

    before do
      stub_sncr_mock!
      allow(Sncr::Config).to receive(:credentials)
        .and_return("base_url" => ControlledPrescriptionHelpers::SNCR_REAL_BASE, "auth_url" => ControlledPrescriptionHelpers::SNCR_REAL_AUTH,
                    "maintainer_cnpj" => real_cnpj)
      linked_certificate!(doctor)
    end

    # As linhas de 8 pt do rodapé colidem no grid do page.text: lê os trechos de texto.
    def runs(document) = PDF::Reader.new(StringIO.new(ClinicalDocuments::Pdf.call(document))).pages.flat_map { |page| page.runs.map(&:text) }.join("\n")

    def mock!(city, enabled) = Platform::Features.set!(city: city, key: "sncr_mock", enabled: enabled, maintainer: ledi_maintainer!)

    it "número real impresso com a cidade já no simulado: CNPJ real" do
      city = controlled_city!(mock: false)
      sncr_stock!(doctor, kind: "rce", count: 1, simulated: false)
      document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
      mock!(city, true)
      text = runs(document)
      expect(text).to include("CNPJ #{Cnpj.display(real_cnpj)}")
      expect(text).not_to include(Cnpj.display(Sncr::Config::SIMULATED_CNPJ))
    end

    it "número simulado impresso com a cidade já no real: CNPJ do simulado" do
      city = controlled_city!(mock: true)
      sncr_stock!(doctor, kind: "rce", count: 1, simulated: true)
      document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
      mock!(city, false)
      text = runs(document)
      expect(text).to include("CNPJ #{Cnpj.display(Sncr::Config::SIMULATED_CNPJ)}")
      expect(text).not_to include(Cnpj.display(real_cnpj))
    end
  end

  it "RCE digital com número real: sem faixa de simulado" do
    controlled_city!(mock: false)
    linked_certificate!(doctor)
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: false)
    document = issue!("items" => [ rce_item ], "patient_identification" => patient_identification)
    expect(pages(document).join).to include("Nº 2610.1-41.0000001")
    expect(pages(document).join).not_to include("NUMERAÇÃO SIMULADA")
  end
end
