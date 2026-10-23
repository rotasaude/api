require "rails_helper"

# Contrato §3 (linhas da cidade). Revisão final da branch, Minors 4 e 8.
RSpec.describe CareLines::SaveLine do
  before do
    care_city!
    care_lines_loaded!
  end

  let(:admin) { care_admin! }
  let(:mental) do
    { "name" => "Saúde mental", "declared_condition" => "mental_health",
      "eligibility" => { "problems" => { "ciap2" => %w[P74] }, "declared" => %w[mental_health] },
      "practices" => [ { "key" => "sm_a", "label" => "Consulta a cada 3 meses", "source" => "consultation", "anchor" => "rolling",
                         "window_days" => 92 } ] }
  end

  # Minor 4: hash virava StatementInvalid (500); array adotava uma versão qualquer.
  describe "template_version precisa ser um inteiro" do
    it "na adoção: hash, array, texto e fracionário → template_not_found, sem gravar; inteiro ou texto de dígitos adota" do
      [ { "a" => 1 }, [ 1 ], [ 1, 2 ], "1a", 1.5, true, 2**40 ].each do |version|
        result = described_class.call(params: { "template_key" => "diabetes_c4", "template_version" => version }, by: admin)
        expect(result.reason).to eq(:template_not_found), "template_version=#{version.inspect}"
      end
      expect(CareLine.count).to eq(0)
      expect(described_class.call(params: { "template_key" => "diabetes_c4", "template_version" => "1" }, by: admin)).to be_ok
      expect(described_class.call(params: { "template_key" => "elderly_c6", "template_version" => 1 }, by: admin)).to be_ok
    end

    it "na readoção: hash e array → template_not_found, sem mudar a linha" do
      line = described_class.call(params: { "template_key" => "diabetes_c4", "template_version" => 1 }, by: admin).payload[:line]
      [ { "v" => 1 }, [ 1 ] ].each do |version|
        expect(described_class.call(params: { "template_version" => version }, by: admin, line: line).reason).to eq(:template_not_found)
      end
      expect(described_class.call(params: { "template_version" => 1 }, by: admin, line: line)).to be_ok
    end
  end

  # Minor 8 (decisão: recusar, como o Rules faz com toda regra; nada é
  # consertado em silêncio). O Suggest só olha eligibility.declared: a linha
  # com declared_condition fora dali nunca sugeriria pela declaração.
  describe "declared_condition precisa estar em eligibility.declared" do
    it "na criação: fora (ou sem declared) → invalid_eligibility em eligibility.declared; dentro cria" do
      outside = mental.merge("eligibility" => { "problems" => { "ciap2" => %w[P74] }, "declared" => %w[diabetes] })
      missing = mental.merge("eligibility" => { "problems" => { "ciap2" => %w[P74] } })
      [ outside, missing ].each do |params|
        result = described_class.call(params: params, by: admin)
        expect([ result.reason, result.details[:field] ]).to eq([ :invalid_eligibility, "eligibility.declared" ])
      end
      expect(CareLine.count).to eq(0)
      expect(described_class.call(params: mental, by: admin)).to be_ok
    end

    it "na edição: trocar só a condição, ou só a elegibilidade, também confere o par" do
      line = described_class.call(params: mental, by: admin).payload[:line]
      result = described_class.call(params: { "declared_condition" => "hypertension" }, by: admin, line: line)
      expect([ result.reason, result.details[:field] ]).to eq([ :invalid_eligibility, "eligibility.declared" ])
      result = described_class.call(params: { "eligibility" => { "problems" => { "ciap2" => %w[P74] } } }, by: admin, line: line)
      expect([ result.reason, result.details[:field] ]).to eq([ :invalid_eligibility, "eligibility.declared" ])
      expect(line.reload).to have_attributes(declared_condition: "mental_health", eligibility: mental["eligibility"])
      expect(described_class.call(params: { "declared_condition" => nil, "eligibility" => { "problems" => { "ciap2" => %w[P74] } } },
                                  by: admin, line: line)).to be_ok
    end
  end
end
