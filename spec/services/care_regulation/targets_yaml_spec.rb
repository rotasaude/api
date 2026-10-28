# spec/services/care_regulation/targets_yaml_spec.rb
require "rails_helper"

RSpec.describe "Catálogo de alvos reguláveis (Task 0)" do
  let(:specialties) { YAML.safe_load_file(Rails.root.join("config/regulation/specialties.yml")) }
  let(:procedures) { YAML.safe_load_file(Rails.root.join("config/regulation/procedures.yml")) }

  it "especialidades: CBO 2002 de 6 dígitos, médicas 225* e odontológicas 2232*, sem repetição nem APS" do
    rows = specialties.fetch("specialties")
    expect(rows).not_to be_empty
    rows.each do |row|
      expect(row["code"]).to match(CareRegulation::Catalog::SPECIALTY_CODE)
      expect(row["name"].length).to be_between(3, CareRegulation::Catalog::NAME_MAX)
      expect(row["label"].to_s.length).to be_between(3, CareRegulation::Catalog::NAME_MAX)
      prefix = row["group"] == "dental" ? CareRegulation::Catalog::DENTIST_PREFIX : CareRegulation::Catalog::PHYSICIAN_PREFIX
      expect(row["code"]).to start_with(prefix)
    end
    codes = rows.map { |r| r["code"] }
    expect(codes.uniq.size).to eq(codes.size)
    expect(codes).to include("225120", "225265", "225270", "225133", "225250", "225124", "223212", "223248")
    expect(codes).not_to include("225125", "225142", "225170", "225130", "223208", "223293", "225106", "223204", "225325", "225320")
    expect(specialties.fetch("excluded")).to all(include("code", "reason"))
  end

  it "especialidades: label de exibição único, sem o título da ocupação (G12 #6)" do
    rows = specialties.fetch("specialties")
    labels = rows.map { |r| r["label"] }
    expect(labels.uniq.size).to eq(labels.size)
    expect(labels.grep(/\A(Médico|Cirurgião-dentista)/)).to be_empty
    expect(rows.find { |r| r["code"] == "225120" }["label"]).to eq("Cardiologia")
    expect(rows.find { |r| r["code"] == "223212" }["label"]).to eq("Endodontia")
  end

  it "nome do prestador de 3 a 120 caracteres (G5)" do
    expect(CareRegulation::Catalog::PROVIDER_NAME).to eq(3..120)
  end

  it "procedimentos: grupos 02–04, BPA sim (APAC principal não exclui, G11), com exemplos conferidos" do
    expect(procedures).to include("groups" => %w[02 03 04], "bpa_instruments" => %w[01 02], "apac_principal_instruments" => %w[06])
    # G11: regulável ⇔ grupo 02–04 E algum BPA; APAC principal (06) é só referência e não exclui.
    expect(procedures.dig("examples", "regulable").size).to be >= 2
    expect(procedures.dig("examples", "not_regulable").size).to be >= 2
    expect(procedures.dig("examples", "regulable")).to all(match(CareRegulation::Catalog::PROCEDURE_CODE))
    expect(procedures.dig("examples", "not_regulable")).to all(match(CareRegulation::Catalog::PROCEDURE_CODE))
    # Os exemplos seguem a regra G11 contra o arquivo vendorizado (rl_procedimento_registro: código 1–10, registro 11–12).
    instruments = Hash.new { |h, k| h[k] = [] }
    Rails.root.join("vendor/regulation/2026-10-28/rl_procedimento_registro.txt").each_line(chomp: true) do |line|
      instruments[line.byteslice(0, 10)] << line.byteslice(10, 2)
    end
    regulable = lambda do |code|
      procedures["groups"].include?(code[0, 2]) && (instruments[code] & procedures["bpa_instruments"]).any?
    end
    expect(procedures.dig("examples", "regulable").map(&regulable)).to all(be(true))
    expect(procedures.dig("examples", "not_regulable").map(&regulable)).to all(be(false))
    expect(procedures.dig("examples", "not_regulable").map { |c| instruments[c] }).to all(be_present)
    expect(Rails.root.join("vendor/regulation/2026-10-28/SOURCE").read).to include("sha256:", "competence:")
  end
end
