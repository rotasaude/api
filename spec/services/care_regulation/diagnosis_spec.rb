require "rails_helper"

# Módulo 26a (ADR 0044; contrato §13 G10, corrigido pelo G12): o diagnóstico do
# pedido. Médico: cid10 obrigatório. Enfermeiro e dentista: cid10 (só se o CBO
# puder) ou ciap2.
RSpec.describe CareRegulation::Diagnosis do
  before { regulation_city! }

  def check(cbo, **over) = described_class.check(cbo: cbo, cid10: nil, ciap2: nil, **over)

  def refusal(result) = [ result.reason, result.details ]

  describe "médico 225125" do
    it "cid10 normalizado (maiúsculo, sem ponto) → ok" do
      result = check("225125", cid10: "i10")
      expect(result).to be_ok
      expect(result.payload).to eq(cid10: "I10", ciap2: nil)
      expect(check("225125", cid10: "e11.9").payload).to eq(cid10: "E119", ciap2: nil)
    end

    it "só ciap2 → diagnosis_required (path cid10); nada → o mesmo" do
      expect(refusal(check("225125", ciap2: "K86"))).to eq([ :diagnosis_required, { path: "cid10" } ])
      expect(refusal(check("225125"))).to eq([ :diagnosis_required, { path: "cid10" } ])
      expect(refusal(check("225125", cid10: ""))).to eq([ :diagnosis_required, { path: "cid10" } ])
    end

    it "cid10 fora da release → invalid_cid10; os dois → ok com os dois" do
      expect(refusal(check("225125", cid10: "Z999"))).to eq([ :invalid_cid10, { path: "cid10" } ])
      expect(check("225125", cid10: "I10", ciap2: "K86").payload).to eq(cid10: "I10", ciap2: "K86")
    end
  end

  describe "dentista 223208 (G12: a regra do enfermeiro)" do
    it "hoje o CBO não registra CID-10: sem ciap2 → diagnosis_required (path ciap2); com ciap2 → ok" do
      expect(refusal(check("223208"))).to eq([ :diagnosis_required, { path: "ciap2" } ])
      expect(check("223208", ciap2: "k86").payload).to eq(cid10: nil, ciap2: "K86")
    end

    it "cid10 enviado → cid10_not_allowed_for_cbo" do
      expect(refusal(check("223208", cid10: "I10", ciap2: "K86"))).to eq([ :cid10_not_allowed_for_cbo, { path: "cid10" } ])
    end
  end

  describe "enfermeira 223505" do
    it "ciap2 sozinho → ok, normalizado, cid10 nil" do
      result = check("223505", ciap2: "k86")
      expect(result).to be_ok
      expect(result.payload).to eq(cid10: nil, ciap2: "K86")
    end

    it "nada → diagnosis_required com path ciap2" do
      expect(refusal(check("223505"))).to eq([ :diagnosis_required, { path: "ciap2" } ])
    end

    it "cid10 → cid10_not_allowed_for_cbo, a menos que já estivesse no pedido (complemento)" do
      expect(refusal(check("223505", cid10: "I10"))).to eq([ :cid10_not_allowed_for_cbo, { path: "cid10" } ])
      expect(refusal(check("223505", cid10: "I10", kept_cid10: "E119"))).to eq([ :cid10_not_allowed_for_cbo, { path: "cid10" } ])
      kept = check("223505", cid10: "I10", kept_cid10: "I10")
      expect(kept).to be_ok
      expect(kept.payload).to eq(cid10: "I10", ciap2: nil)
      expect(check("223505", cid10: "i10", kept_cid10: "I10").payload).to eq(cid10: "I10", ciap2: nil)
    end

    it "o cid10 do pedido conta mesmo quando o complemento não o repete" do
      result = check("223505", kept_cid10: "I10")
      expect(result.payload).to eq(cid10: "I10", ciap2: nil)
    end

    it "ciap2 fora da release → invalid_ciap2" do
      expect(refusal(check("223505", ciap2: "K99"))).to eq([ :invalid_ciap2, { path: "ciap2" } ])
    end
  end

  describe "ordem das recusas" do
    it "tipo errado vem primeiro, com o path da chave" do
      expect(refusal(check("225125", cid10: 10))).to eq([ :invalid_request, { path: "cid10" } ])
      expect(refusal(check("225125", cid10: "I10", ciap2: [ "K86" ]))).to eq([ :invalid_request, { path: "ciap2" } ])
      expect(refusal(check("225125", cid10: "Z999", ciap2: 1))).to eq([ :invalid_request, { path: "ciap2" } ])
    end

    it "código inexistente vem antes da regra do papel" do
      expect(refusal(check("223505", cid10: "Z999"))).to eq([ :invalid_cid10, { path: "cid10" } ])
      expect(refusal(check("225125", cid10: "I10", ciap2: "K99"))).to eq([ :invalid_ciap2, { path: "ciap2" } ])
    end
  end
end
