require "rails_helper"

# Desvio 14: valor SIGTAP (VL_SA, centavos) lido quando o layout traz a coluna.
RSpec.describe "SIGTAP: valor do procedimento" do
  it "importa VL_SA do recorte" do
    Dir.mktmpdir do |dir|
      result = Terminology::Import.call(kind: "sigtap", version: "202610", path: SigtapSample.write_to(dir, competence: "202610"), by: "rspec")
      expect(result).to be_ok
      release = TerminologyRelease.find_by!(kind: "sigtap", version: "202610")
      expect(SigtapProcedure.find_by!(release: release, code: "0202020380").amount_sa_cents).to eq(411)
      expect(SigtapProcedure.find_by!(release: release, code: "0301010064").amount_sa_cents).to be_nil
    end
  end
end
