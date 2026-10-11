require "rails_helper"

# ADR 0033 (spec §6; contrato §9, §12): o JSON canônico do documento clínico na
# forma EXATA do esquema da tag clinical-v1.2.0 (cópia em config/clinical/;
# ADR 0034: receita comum na forma da 1.1.0, RCE/RET com category),
# provado byte a byte contra os vetores do contracts; o construtor produz JSON
# válido para os quatro tipos e é determinístico.
RSpec.describe "JSON canônico rotasaude.clinical_document.v1" do
  dir = Rails.root.join("spec/fixtures/clinical")
  examples = "clinical-document" # clinical/examples/clinical-document/ da tag clinical-v1.2.0
  sums = File.read(dir.join("canonical/SHA256SUMS")).lines.to_h { |line| line.split.then { |sha, name| [ name, sha ] } }
  schema = Signatures::Canonical::DOCUMENT_SCHEMA
  vectors = %w[prescription-doctor sick-note-leave prescription-dosage-form-null prescription-special-control prescription-ret]

  JSON.parse(File.read(dir.join(examples, "manifest.json"))).fetch("cases").each do |c|
    it "#{examples}/#{c['file']}: #{c['expect']}" do
      document = JSON.parse(File.read(dir.join(examples, c["file"])))
      if c["expect"] == "valid"
        expect { Signatures::Canonical.validate!(schema, document) }.not_to raise_error
        jcs = "#{File.basename(c['file'], '.json')}.jcs"
        if sums.key?(jcs)
          out = Signatures::Jcs.dump(document)
          expect(out.b).to eq(File.binread(dir.join("canonical", jcs)))
          expect(Digest::SHA256.hexdigest(out)).to eq(sums.fetch(jcs))
        end
      else
        expect { Signatures::Canonical.validate!(schema, document) }
          .to raise_error(Signatures::Canonical::Invalid, /#{Regexp.escape(c['expect'].split.first)}/)
      end
    end
  end

  it "os vetores do documento clínico são os publicados nas tags clinical-v1.1.0 e clinical-v1.2.0" do
    expect(Digest::SHA256.file(Rails.root.join("config/clinical/clinical-document-v1.json")).hexdigest)
      .to eq("e195e85fcf4468ff2a071ed8e05bb1afc3d0490420a92557b0561fbd292c6c29")
    expect(JSON.parse(File.read(dir.join(examples, "manifest.json"))).fetch("cases").size).to eq(85)
    expect(sums).to include("prescription-special-control.jcs" => "25538e7fb3c406a8a84a785069307297097b338c460d15ed2599cf7df2bb2e0a",
                            "prescription-ret.jcs" => "e4397d409d2e9bc5a625e6e8bce4ab0d1539e4f1d7f4c2256c7812a95f170464")
    expect(sums).to include("prescription-doctor.jcs" => "62bd59faef736229bfc314adb643a128fa557f4434c6277085f031efa1c170f5",
                            "sick-note-leave.jcs" => "171c46109f960cdebb7c78dba67a29d2d6e548cb84bd29961145a8cb3bc77afc",
                            "prescription-dosage-form-null.jcs" =>
                              "6394b4339ef9a6d9869c5bfe6a96985e7b0812d7323906c8136778dabb31a8a5")
  end

  # Ida e volta: o conteúdo do exemplo, passado pelo ClinicalDocuments::Canonical
  # (normalização de note, catalog_release, opcionais e CID), dá os mesmos bytes
  # do vetor — a normalização não muda documento já canônico.
  vectors.each do |name|
    it "#{name}: o construtor reproduz o vetor byte a byte" do
      example = JSON.parse(File.read(dir.join(examples, "#{name}.json")))
      document = instance_double(ClinicalDocument, kind: example.dig("document", "kind"), content_data: example["content"].deep_dup)
      rebuilt = example.merge("content" => ClinicalDocuments::Canonical.content(document))
      expect { Signatures::Canonical.validate!(schema, rebuilt) }.not_to raise_error
      expect(Signatures::Jcs.dump(rebuilt).b).to eq(File.binread(dir.join("canonical", "#{name}.jcs")))
    end
  end

  describe "normalização do conteúdo" do
    def content(kind, data) = ClinicalDocuments::Canonical.content(instance_double(ClinicalDocument, kind: kind, content_data: data))

    it "CID-10 com a normalização da entrada (atestado e justificativa do exame)" do
      expect(content("sick_note", { "type" => "leave", "days" => 1, "cid10" => { "code" => " j06.9 ", "label" => "X" },
                                    "cid_authorized" => true, "note" => "" }))
        .to eq("type" => "leave", "days" => 1, "cid10" => { "code" => "J069", "label" => "X" }, "cid_authorized" => true, "note" => nil)
      exams = content("exam_requisition", { "exams" => [ { "sigtap_code" => "0202010503", "competence" => "202610", "label" => "Y",
                                                         "cid10_justification" => "e11.9" } ] })["exams"]
      expect(exams).to eq([ { "sigtap_code" => "0202010503", "competence" => "202610", "label" => "Y", "cid10_justification" => "E119" } ])
    end

    it "acompanhante sem a chave days; start_on mantido" do
      expect(content("sick_note", { "type" => "companion", "days" => nil, "start_on" => "2026-10-09", "companion_name" => "Maria",
                                    "companion_kinship" => "mãe", "companion_reason" => "other", "cid_authorized" => false }))
        .to eq("type" => "companion", "start_on" => "2026-10-09", "companion_name" => "Maria", "companion_kinship" => "mãe",
               "companion_reason" => "other", "cid_authorized" => false, "note" => nil)
    end

    it "receita só de texto livre: catalog_release presente e null; opcionais nulos ausentes" do
      data = { "items" => [ { "position" => 1, "catalog_item" => nil, "free_text" => "Chá", "printed_description" => "Chá",
                              "quantity" => 1, "quantity_unit" => "caixa", "route" => "oral", "dosage_instructions" => "à noite",
                              "duration_days" => nil, "continuous" => false, "antimicrobial" => false } ],
               "antimicrobial" => false, "copies" => 1 }
      result = content("prescription", data)
      expect(result).to include("catalog_release" => nil)
      expect(result["items"].sole.keys).not_to include("catalog_item", "duration_days")
    end

    # clinical-v1.2.0 (ADR 0034; contrato §12): a comum do 19d grava category
    # e os nulos, mas o canônico é o da 1.1.0 — uma só representação.
    it "receita comum do 19d: sem category e sem as chaves nulas (forma da 1.1.0)" do
      stored = controlled_content("common")
      expect(stored).to include("category" => "common", "sncr" => nil, "patient_identification" => nil, "prescriber_contact" => nil)
      result = content("prescription", stored)
      expect(result.keys).not_to include("category", "sncr", "patient_identification", "prescriber_contact")
      expect(result).to eq(content("prescription", stored.except("category", "sncr", "patient_identification", "prescriber_contact")))
    end

    it "RCE e RET: category presente; nulos, complemento vazio, paper_reason e marcas do catálogo fora; válido no esquema" do
      { "special_control" => "prescription-special-control", "antimicrobial" => "prescription-ret" }.each do |category, name|
        stored = controlled_content(category, "paper_reason" => nil)
        stored["items"].first["catalog_item"].merge!("controlled_list" => category == "special_control" ? "C1" : nil, "anticonvulsant" => false)
        stored["prescriber_contact"] = stored["prescriber_contact"].merge("address" => ControlledPrescriptionHelpers::ADDRESS.merge("complement" => nil))
        result = content("prescription", stored)
        expect(result).to include("category" => category)
        expect(result).not_to have_key("paper_reason")
        expect(result["items"].sole["catalog_item"].keys).not_to include("controlled_list", "anticonvulsant")
        expect(result["prescriber_contact"]["address"]).not_to have_key("complement")
        expect(result.key?("patient_identification")).to eq(category == "special_control")
        example = JSON.parse(File.read(dir.join(examples, "#{name}.json")))
        expect { Signatures::Canonical.validate!(schema, example.merge("content" => result)) }.not_to raise_error
      end
    end
  end

  describe "construtor" do
    before { documents_city!; ciap2_release!; cid10_release!; sigtap_release!; city_profile!; import_test_catalog! }

    let(:unit) { create_unit }
    let(:doctor) { doctor!(unit).tap { |user| user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) } }
    let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

    def issue!(kind, content) = ClinicalDocuments::Issue.call(kind: kind, content: content, by: doctor, consultation: consultation).payload.fetch(:document)

    it "os quatro tipos saem válidos no esquema, com o cabeçalho da consulta" do
      documents = [
        issue!("sick_note", { "type" => "leave", "days" => 2, "cid10" => { "code" => "I10" }, "cid_authorized" => true }),
        issue!("attendance_declaration", {}),
        issue!("prescription", { "items" => [ { "catalog_item" => { "id" => catalog_item(267_778).id }, "quantity" => 30,
                                                "quantity_unit" => "comprimido", "route" => "oral",
                                                "dosage_instructions" => "1 comprimido se dor", "continuous" => true },
                                              { "free_text" => "Chá de camomila", "quantity" => 1.5, "quantity_unit" => "caixa",
                                                "route" => "oral", "dosage_instructions" => "1 sachê à noite" } ] }),
        issue!("exam_requisition", { "note" => "" })
      ]
      documents.each do |document|
        built = Signatures::Canonical.clinical_document(document)
        expect(built.document).to include("schema" => "rotasaude.clinical_document.v1",
                                          "document" => { "id" => document.id, "kind" => document.kind,
                                                          "issued_at" => document.issued_at.utc.iso8601, "replaces_document_id" => nil },
                                          "professional" => include("cpf" => SignatureHelpers::DOCTOR_CPF, "cbo_code" => "225125"))
        expect(Signatures::Canonical.for(document).sha256).to eq(built.sha256)
        expect(Signatures::Canonical.clinical_document(document.reload).sha256).to eq(built.sha256) # determinístico
      end
      prescription = Signatures::Canonical.clinical_document(documents[2]).document["content"]
      expect(prescription["catalog_release"]).to eq(catalog_item(267_778).last_release_id)
      expect(prescription.keys).not_to include("category", "sncr", "patient_identification", "prescriber_contact")
      expect(documents[2].content_data).to include("category" => "common")
      expect(prescription["items"].first).to include("catalog_item" => include("catmat_code" => 267_778, "dosage_form" => "comprimido"),
                                                     "quantity" => 30, "continuous" => true)
      expect(prescription["items"].first).not_to have_key("free_text")
      expect(prescription["items"].second).to include("free_text" => "Chá de camomila", "quantity" => 1.5)
      expect(prescription["items"].second).not_to have_key("catalog_item")
      expect(Signatures::Canonical.clinical_document(documents[3]).document["content"]["note"]).to be_nil
    end

    it "item do catálogo sem forma farmacêutica sai com dosage_form null e assina (decisão do usuário, 2026-10-10)" do
      document = issue!("prescription", { "items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30,
                                                         "quantity_unit" => "comprimido", "route" => "oral",
                                                         "dosage_instructions" => "1 comprimido pela manhã" } ] })
      item = Signatures::Canonical.clinical_document(document).document["content"]["items"].first
      expect(item["catalog_item"]).to include("catmat_code" => 268_856, "dosage_form" => nil)
      expect(item["catalog_item"]).to have_key("dosage_form")
    end

    it "declaração da recepção não é assinável" do
      reception = ClinicalDocuments::Issue.call(kind: "attendance_declaration", content: {}, by: verifier!,
                                                attendance: consultation.attendance).payload[:document]
      expect { Signatures::Canonical.clinical_document(reception) }.to raise_error(Signatures::Canonical::Invalid, /not_signable/)
    end
  end
end
