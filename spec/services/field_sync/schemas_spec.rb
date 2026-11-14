require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.4): a cópia dos esquemas do field-sync em
# config/field_sync/ é a do rotasaude/contracts, presa por SHA-256; os exemplos
# do manifest do contracts (cópia em spec/fixtures/field_sync/examples/) dão o
# mesmo resultado aqui, com o json_schemer do api. Os SHA são os da tag
# field-sync-v1.2.0 do rotasaude/contracts (módulo 24c, ADR 0053).
RSpec.describe "FieldSync::Schemas (contrato field-sync-v1)" do
  let(:examples) { Rails.root.join("spec/fixtures/field_sync/examples") }

  # Literais de propósito: o spec não lê FieldSync::Schemas::SHA256 para saber o esperado.
  let(:pinned) do
    {
      "session-response-v1" => "b3615de707cc235457b2c94a62823f332c244a700a1c6444144f204bb82eb6fc",
      "upload-request-v1" => "c971a785ceabd27602ee92765c656443b8d9e803c59c90bfb9c9b4e7d40c0284",
      "upload-response-v1" => "4c9c04191030504bb13749bf57261d749f03e4c8782bc0f26a1edca1bf7cedb9",
      "changes-response-v1" => "8c19be1cb7f72c98ff488acb1749daec0e1eba03efb99ec47640efd576c31882",
      "reference-response-v1" => "484e0aabe3f3a3ff6e71fcae32c5f98ec5d36331cae7521ce97b03ad094f0a36",
      "domains-v1" => "554d5b2353a26c19c2ae8a6be50055c04743be0d4fb39f24a790f5386f96c547"
    }
  end

  it "a cópia bate com o SHA-256 da v1.2.0 do contracts" do
    expect(Dir[Rails.root.join("config/field_sync/*.json")].map { |path| File.basename(path, ".json") }).to match_array(pinned.keys)
    pinned.each do |name, sha|
      expect(Digest::SHA256.file(Rails.root.join("config/field_sync/#{name}.json")).hexdigest).to eq(sha), name
    end
    expect(FieldSync::Schemas::SHA256).to eq(pinned)
  end

  it "arquivo alterado não carrega (falha fechada, sem o conteúdo na mensagem)" do
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(FieldSync::Schemas::DIR.join("session-response-v1.json")).and_return(%({"type":"object","x":"segredo"}))
    expect { FieldSync::Schemas.send(:load_document, "session-response-v1") }
      .to raise_error(FieldSync::Schemas::Tampered) { |error| expect(error.message).not_to include("segredo") }
  end

  it "os exemplos do manifest do contracts validam" do
    manifest = JSON.parse(File.read(examples.join("manifest.json")))
    files = manifest.fetch("suites").flat_map { |suite| suite.fetch("cases").map { |c| c.fetch("file") } }
    expect(files.size).to eq(124)
    expect(Dir[examples.join("*.json")].map { |path| File.basename(path) } - [ "manifest.json" ]).to match_array(files)

    outcomes = manifest.fetch("suites").flat_map do |suite|
      name = suite.fetch("schema").delete_suffix(".json")
      suite.fetch("cases").map do |c|
        doc = JSON.parse(File.read(examples.join(c.fetch("file"))))
        got = FieldSync::Schemas.errors(name, doc).map { |error| "#{error[:pointer].presence || '(root)'} #{error[:type]}" }.uniq
        ok = c.fetch("expect") == "valid" ? got.empty? : got.include?(c.fetch("expect"))
        [ c.fetch("file"), ok, c.fetch("expect"), got ]
      end
    end
    expect(outcomes.reject { |_, ok| ok }).to eq([])
    expect(outcomes.count { |_, _, expected| expected == "valid" }).to eq(49)
  end

  describe "em execução (preflight 1.16, usado pela Task 20)" do
    let(:session) { JSON.parse(File.read(examples.join("session-acs.json"))) }

    it "validate! passa o válido e recusa o inválido só com ponteiro e palavra-chave, nunca o valor" do
      expect(FieldSync::Schemas.validate!("session-response-v1", session)).to be(true)
      expect(FieldSync::Schemas.valid?("session-response-v1", session)).to be(true)

      bad = session.merge("token" => "rsf_segredo-que-nao-pode-vazar")
      expect(FieldSync::Schemas.valid?("session-response-v1", bad)).to be(false)
      expect { FieldSync::Schemas.validate!("session-response-v1", bad) }.to raise_error(FieldSync::Schemas::Invalid) do |error|
        expect(error.message).to include("/token schema")
        expect(error.message).not_to include("segredo")
        expect(error.errors).to eq([ { pointer: "/token", type: "schema" } ])
      end
    end

    it "errors(ref: '#/$defs/item') valida um item do envio sozinho" do
      upload = JSON.parse(File.read(examples.join("upload-home-visit-resident.json")))
      item = upload.fetch("items").first
      expect(FieldSync::Schemas.errors("upload-request-v1", item, ref: "#/$defs/item")).to eq([])

      broken = item.merge("type" => "visit_sheet")
      expect(FieldSync::Schemas.errors("upload-request-v1", broken, ref: "#/$defs/item")).not_to be_empty
      expect(FieldSync::Schemas.errors("upload-request-v1", broken, ref: "#/$defs/item").map(&:keys).uniq).to eq([ %i[pointer type] ])
    end

    it "nome desconhecido é erro de programação" do
      expect { FieldSync::Schemas.errors("outro-v1", {}) }.to raise_error(KeyError)
    end

    it "domains devolve o domains-v1.json" do
      expect(FieldSync::Schemas.domains.dig("errors", "http")).to include("invalid_token", "device_revoked", "json_required")
    end
  end
end
