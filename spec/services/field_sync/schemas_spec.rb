require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.4): a cópia dos esquemas do field-sync em
# config/field_sync/ é a do rotasaude/contracts, presa por SHA-256; os exemplos
# do manifest do contracts (cópia em spec/fixtures/field_sync/examples/) dão o
# mesmo resultado aqui, com o json_schemer do api. A tag field-sync-v1.0.0 ainda
# não saiu (C-HOLD): os SHA são os do commit fb52430 do contracts, e a Task 26
# re-prende na tag.
RSpec.describe "FieldSync::Schemas (contrato field-sync-v1)" do
  let(:examples) { Rails.root.join("spec/fixtures/field_sync/examples") }

  # Literais de propósito: o spec não lê FieldSync::Schemas::SHA256 para saber o esperado.
  let(:pinned) do
    {
      "session-response-v1" => "199957bcf5b9d16645cf1a05e9cbbb210001474556a6ab3104783f49a1660bb0",
      "upload-request-v1" => "a372ebf5b53a1812d18efc2e29c735807f8cd62a5071540ba9f83363657e3e6f",
      "upload-response-v1" => "820bf2a8fb1fc8bb718141c6adc4663be01eda84450471fa142811fe27ce77de",
      "changes-response-v1" => "baa2022a2661a2eb928133912e0eebc7d820d9a2fcfa6cba43a437098effc022",
      "domains-v1" => "f13abb21a96ff7946c27e2859f26d529e33d6f0f727c59571d1091f179e5510c"
    }
  end

  it "a cópia bate com o SHA-256 do commit fb52430 do contracts (a T26 re-prende na tag)" do
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
    expect(files.size).to eq(86)
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
    expect(outcomes.count { |_, _, expected| expected == "valid" }).to eq(33)
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

      broken = item.merge("type" => "family")
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
