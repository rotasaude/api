require "rails_helper"
require "csv"

# Módulo 25, Task 15 (contrato §7, K7, K10): o CSV semanal. A semana é a da
# SUSPEITA; possible/dismissed não entram; sem CPF; CNS só os 4 últimos dígitos.
RSpec.describe Surveillance::Csv do
  before { surveillance_city! }

  let(:week) { Surveillance::EpiWeek.new(year: 2026, week: 42) } # 18 a 24/10/2026
  let(:unit) { create_unit("UBS Vigia").tap { |u| u.update!(cnes: "2345678") } }

  def at(date) = Time.zone.local(date.year, date.month, date.day, 12)

  def case!(n, on:, status: "notified", **over)
    notification!(patient: surveillance_patient!(n), unit: unit, suspected_at: at(on), status: status, **over)
  end

  def parse(text)
    expect(text).to start_with("﻿")
    CSV.parse(text.delete_prefix("﻿"), col_sep: ";", headers: true)
  end

  it "tem o cabeçalho fixo, UTF-8 com BOM e ;" do
    text = described_class.call(week: week)

    expect(text).to start_with("﻿")
    expect(text.encoding).to eq(Encoding::UTF_8)
    expect(text.delete_prefix("﻿").lines.first.chomp).to eq(
      "semana;notificacao_id;data_notificacao;data_primeiros_sintomas;doenca_codigo;doenca;cid10_ficha;prazo;situacao;" \
      "classificacao;numero_oficial;unidade_cnes;unidade;paciente;cns_final;sexo;nascimento;bairro;" \
      "residente_outro_municipio;ibge_residencia"
    )
    expect(parse(text).size).to eq(0)
  end

  it "uma linha por notificação da semana: a da semana seguinte e a possible ficam de fora" do
    inside = case!(1, on: week.starts_on, symptoms_on: week.starts_on - 2)
    last_day = case!(2, on: week.ends_on, disease_code: "sarampo")
    case!(3, on: week.ends_on + 1)
    case!(4, on: week.starts_on - 1)
    case!(5, on: week.starts_on + 1, status: "possible")
    dismissed = case!(6, on: week.starts_on + 2, status: "possible")
    dismissed.update_columns(status: "dismissed", dismissed_at: Time.current)

    rows = parse(described_class.call(week: week))

    expect(rows.map { |r| r["notificacao_id"] }).to match_array([ inside.id, last_day.id ])
    row = rows.find { |r| r["notificacao_id"] == inside.id }
    expect(row.to_h).to include("semana" => "2026-42", "data_notificacao" => "18/10/2026", "data_primeiros_sintomas" => "16/10/2026",
                                "doenca_codigo" => "dengue", "doenca" => Surveillance::Diseases.find("dengue").name,
                                "cid10_ficha" => Surveillance::Diseases.find("dengue").cid10.join(","),
                                "prazo" => inside.deadline, "situacao" => "notified", "unidade_cnes" => "2345678",
                                "unidade" => "UBS Vigia", "residente_outro_municipio" => "não")
  end

  it "build devolve os ids das linhas (para a trilha)" do
    a = case!(1, on: week.starts_on)
    case!(2, on: week.ends_on + 1)

    expect(described_class.build(week: week).fetch(:ids)).to eq([ a.id ])
  end

  it "não leva CPF; o CNS só com os 4 últimos dígitos" do
    cns = valid_cns(3)
    patient = Patient.create!(full_name: "Lia Santos", birth_date: "1990-05-01", sex: "female", no_cpf_reason: "3", cns: cns)
    cpf_patient = surveillance_patient!(9)
    notification!(patient: patient, unit: unit, suspected_at: at(week.starts_on))
    notification!(patient: cpf_patient, unit: unit, suspected_at: at(week.starts_on))

    text = described_class.call(week: week)
    rows = parse(text)

    expect(text).not_to include(cpf_patient.cpf, cns)
    expect(rows.map { |r| r["cns_final"] }).to include(cns.last(4))
    rows.each do |row|
      expect(row["cns_final"].to_s).to match(/\A(\d{4})?\z/)
      # ids (UUID) e CNES/IBGE não têm 11 dígitos seguidos; o resto nunca
      expect(row.to_h.except("notificacao_id", "cns_final").values.join(";")).not_to match(/\d{11}/)
    end
    lia = rows.find { |r| r["paciente"] == "Lia Santos" }
    expect(lia.to_h).to include("sexo" => "F", "nascimento" => "01/05/1990")
  end

  it "célula de texto que começa como fórmula sai neutralizada (Exams::Report.safe_cell)" do
    patient = surveillance_patient!(4)
    patient.update!(social_name: "=HYPERLINK(\"http://x\")")
    case_row = notification!(patient: patient, unit: unit, suspected_at: at(week.starts_on))
    case_row.update!(official_number: nil)

    rows = parse(described_class.call(week: week))

    expect(rows.first["paciente"]).to eq("'=HYPERLINK(\"http://x\")")
  end

  it "nome com ; ou aspas continua uma célula só" do
    patient = surveillance_patient!(5)
    patient.update!(social_name: 'Ana; "Bia" Souza')
    notification!(patient: patient, unit: unit, suspected_at: at(week.starts_on))

    rows = parse(described_class.call(week: week))

    expect(rows.first["paciente"]).to eq('Ana; "Bia" Souza')
    expect(rows.first.fields.size).to eq(described_class::HEADER.size)
  end
end
