require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.4): a cópia dos esquemas do field-sync em
# config/field_sync/ é a do rotasaude/contracts, presa por SHA-256; os exemplos
# do manifest do contracts (cópia em spec/fixtures/field_sync/examples/) dão o
# mesmo resultado aqui, com o json_schemer do api. Os SHA são os da v1.4.0 do
# rotasaude/contracts (módulo 35b, §11; commit 15379c1, ainda sem tag; a Task
# 20 prende os da tag).
RSpec.describe "FieldSync::Schemas (contrato field-sync-v1)" do
  let(:examples) { Rails.root.join("spec/fixtures/field_sync/examples") }

  # Literais de propósito: o spec não lê FieldSync::Schemas::SHA256 para saber o esperado.
  let(:pinned) do
    {
      "session-response-v1" => "0ecca17934764f012c92f8a2d2f2092a77174867402b4e92c24879a48343e6b9",
      "upload-request-v1" => "1e22ad13bfe061e1aba5b7874d849a451426269974ce99efee5d0ea1319945e9",
      "upload-response-v1" => "04d30d759f88d1caafcb6a5ef37f3af2cc75695ef721e5a306d541e5967565a3",
      "changes-response-v1" => "5154ae0f90b4537fb02a38b1a8d7853991874516dd1dd25834fae29feb36796b",
      "reference-response-v1" => "13e3eb16e2606b8085751e8c930660145732df49a5cef5dba6a28291a1edc29a",
      "domains-v1" => "4346776b7aaee1e8cbfece2228a3fe93a38891533525ccf4f85d2d91a58f7e1b"
    }
  end

  it "a cópia bate com o SHA-256 da v1.4.0 do contracts" do
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
    expect(files.size).to eq(267)
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
    expect(outcomes.count { |_, _, expected| expected == "valid" }).to eq(78)
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
