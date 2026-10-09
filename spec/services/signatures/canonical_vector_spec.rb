require "rails_helper"

# O vetor de canonicalização do contracts (clinical/examples/canonical/, tag
# clinical-v1.0.0, commit ff7df1d): o gerador RFC 8785 do api reproduz os bytes
# e o SHA-256 publicados, e os exemplos de origem passam nos esquemas copiados.
# Os manifestos dos exemplos (válidos e invalid-*) rodam contra as cópias de
# config/clinical/: detector de deriva entre a cópia e a tag.
RSpec.describe "Vetor RFC 8785 do contracts (clinical-v1.0.0)" do
  dir = Rails.root.join("spec/fixtures/clinical")
  let(:sums) do
    File.read(dir.join("canonical/SHA256SUMS")).lines.to_h { |line| line.split.then { |sha, name| [ name, sha ] } }
  end

  it "os SHA-256 publicados são os fixados no contrato" do
    expect(sums).to eq("consultation-full.jcs" => "4caa5160378b1ed8a3a29a6338af1709dd6adbf7744a79e2996e5019d91f4e70",
                       "addendum-structured.jcs" => "6ba35a6bd3dab76bdbe515769608fe30473dd3acc15e280672b8b41e54259279")
  end

  {
    "consultation-full" => [ "consultation/consultation-full.json", Signatures::Canonical::CONSULTATION_SCHEMA ],
    "addendum-structured" => [ "consultation-addendum/addendum-structured.json", Signatures::Canonical::ADDENDUM_SCHEMA ]
  }.each do |name, (source, schema)|
    it "#{name}: mesmos bytes e mesmo SHA-256; o exemplo é válido no esquema" do
      document = JSON.parse(File.read(dir.join(source)))
      expect { Signatures::Canonical.validate!(schema, document) }.not_to raise_error
      out = Signatures::Jcs.dump(document)
      expect(out.b).to eq(File.binread(dir.join("canonical/#{name}.jcs")))
      expect(Digest::SHA256.hexdigest(out)).to eq(sums.fetch("#{name}.jcs"))
    end
  end

  {
    "consultation" => Signatures::Canonical::CONSULTATION_SCHEMA,
    "consultation-addendum" => Signatures::Canonical::ADDENDUM_SCHEMA
  }.each do |folder, schema|
    JSON.parse(File.read(dir.join(folder, "manifest.json"))).fetch("cases").each do |c|
      it "#{folder}/#{c['file']}: #{c['expect']}" do
        document = JSON.parse(File.read(dir.join(folder, c["file"])))
        if c["expect"] == "valid"
          expect { Signatures::Canonical.validate!(schema, document) }.not_to raise_error
        else
          expect { Signatures::Canonical.validate!(schema, document) }.to raise_error(Signatures::Canonical::Invalid, /#{Regexp.escape(c["expect"])}/)
        end
      end
    end
  end
end
