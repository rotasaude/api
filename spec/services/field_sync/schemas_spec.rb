require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.4): a cópia dos esquemas do field-sync em
# config/field_sync/ é a do rotasaude/contracts, presa por SHA-256; os exemplos
# do manifest do contracts (cópia em spec/fixtures/field_sync/examples/) dão o
# mesmo resultado aqui, com o json_schemer do api. Os SHA são os da v1.3.0 do
# rotasaude/contracts (módulo 35a, §13; commit 2b1c24c, ainda sem tag).
RSpec.describe "FieldSync::Schemas (contrato field-sync-v1)" do
  let(:examples) { Rails.root.join("spec/fixtures/field_sync/examples") }

  # Literais de propósito: o spec não lê FieldSync::Schemas::SHA256 para saber o esperado.
  let(:pinned) do
    {
      "session-response-v1" => "ab8b9778841b8c1dea6215b794c2e85b6a0fb6093a74dccd6e12fd5d617d8c74",
      "upload-request-v1" => "5fa0c171be285754c9a1e237eafdbc61b467edd6af9f026efb2552f8b96024e3",
      "upload-response-v1" => "ae211029fda7662b29658f6e94df1cba5c01275db2e98ecc870ebfc50f2337aa",
      "changes-response-v1" => "980a9992ebb549094260a1d02d3daea237ce0e0e1b63d892391600832d66c40b",
      "reference-response-v1" => "d2db3e6ebe806210d15f872ee2012db2db7902acaee25ee25bf028b33d26890e",
      "domains-v1" => "d8b92593e29c72c36c96b64ade69d9e8f8663456bc7f5328cf4c20a9263d6038"
    }
  end

  it "a cópia bate com o SHA-256 da v1.3.0 do contracts" do
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
    expect(files.size).to eq(168)
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
    expect(outcomes.count { |_, _, expected| expected == "valid" }).to eq(61)
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
