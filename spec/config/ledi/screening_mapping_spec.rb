# spec/config/ledi/screening_mapping_spec.rb
require "rails_helper"

# ADR 0030 / spec §5 (Tarefa 1): o mapeamento da escuta para o LEDI 8.7.0 tem
# fonte em cada linha e bate com os IDLs vendorizados.
RSpec.describe Ledi::ScreeningMapping do
  def idl_fields(file, struct)
    text = Rails.root.join("vendor/ledi/8.7.0/idl", file).read
    body = text[/struct\s+#{struct}\s*\{(.*?)\n\}/m, 1] or raise "#{struct} não está em #{file}"
    body.scan(/^\s*\d+:\s*(?:required|optional)\s+[\w.<>]+\s+(\w+)/).flatten
  end

  it "é da versão ativa e toda entrada tem valor e fonte" do
    expect(described_class.data.fetch("ledi_version")).to eq(Ledi::Version::ACTIVE)
    described_class.data.fetch("entries").each do |key, entry|
      expect(entry.keys).to contain_exactly("value", "source"), key
      expect(entry["source"].to_s.strip).not_to be_empty, key
    end
    expect(described_class.data.dig("miai_cbos", "source")).to be_present
    expect(described_class.data.dig("procedures_cbo_prefixes", "source")).to be_present
  end

  it "escuta inicial no MIAI é tipo 4, local UBS, e cada destino tem conduta" do
    expect(described_class.value("initial_listening.tipo_atendimento")).to eq(4)
    expect([ 1, 2, 4, 5, 6 ]).to include(described_class.value("initial_listening.tipo_atendimento"))
    expect(described_class.value("initial_listening.local_de_atendimento")).to eq(1)
    expect(%w[same_day schedule oriented referred].map { |d| described_class.conduta(d) }).to eq([ 11, 1, 9, 4 ])
    expect(described_class.value("tipo_dado_serializado.atendimento_individual")).to eq(4)
  end

  it "os campos de medição existem em MedicoesThrift" do
    fields = idl_fields("ras/common.thrift", "MedicoesThrift")
    columns = %w[systolic diastolic heart_rate respiratory_rate temperature_c spo2 capillary_glucose glucose_moment weight_kg height_cm]
    expect(columns.map { |c| described_class.measurement_field(c) }).to all(satisfy { |f| fields.include?(f) })
    expect(described_class.value("measurement_limit.capillary_glucose_max")).to eq(800)
  end

  it "o MIP marca a escuta, usa só SIGTAP de 10 dígitos e nunca o código da escuta" do
    expect(idl_fields("ras/ficha_atendimento_procedimento.thrift", "FichaProcedimentoChildThrift"))
      .to include("statusEscutaInicialOrientacao", "procedimentos", "medicoes")
    expect(described_class.value("screening_procedures.status_escuta_inicial_orientacao")).to be(true)
    codes = %w[blood_pressure capillary_glucose temperature weight height].map { |k| described_class.procedure(k) }
    expect(codes).to all(match(/\A\d{10}\z/))
    expect(codes).not_to include(described_class.value("screening_procedures.forbidden_procedure"))
  end

  it "CBO: o MIAI tem enfermeiro e médicos e nenhum técnico; 3222 vai para o MIP" do
    expect(described_class.miai_cbos).to include("223505", "225125", "225142")
    expect(described_class.miai_cbos).to all(match(/\A[0-9A-Z]{6}\z/))
    expect(described_class.miai_cbos.grep(/\A3222/)).to be_empty
    expect(described_class.miai_cbo?("322205")).to be(false)
    expect(described_class.procedures_cbo?("322205")).to be(true)
    expect(described_class.exportable_cbo?("223505")).to be(true)
    expect(described_class.exportable_cbo?("223293")).to eq(described_class.miai_cbos.include?("223293"))
  end

  it "códigos de sexo, glicemia e turno; CPF é o identificador" do
    expect([ described_class.sex_code("male"), described_class.sex_code("female") ]).to eq([ 0, 1 ])
    expect(%w[fasting postprandial random].map { |m| described_class.glucose_code(m) }).to eq([ 0, 1, 3 ])
    Time.use_zone("America/Sao_Paulo") do
      expect([ 8, 13, 19 ].map { |h| described_class.turno(Time.zone.parse("2026-10-07 #{h}:00")) }).to eq([ 1, 2, 3 ])
    end
    expect(described_class.value("citizen_identifier")).to eq("cpf")
  end

  it "técnico sem aferição ainda gera MIP só com a marca da escuta (decisão do PO, fonte registrada)" do
    entry = described_class.entry("screening_procedures.flag_only_accepted")
    expect(entry["value"]).to be(true)
    expect(entry["source"]).to include("dicionario-fp.html", "statusEscutaInicialOrientacao")
  end

  it "chave inexistente levanta" do
    expect { described_class.value("nao.existe") }.to raise_error(described_class::Missing)
  end
end
