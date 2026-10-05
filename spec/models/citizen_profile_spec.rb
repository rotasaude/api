require "rails_helper"

# ADR 0027 (spec 2026-10-05 §3.1): perfil cifrado por cidade, idade calculada
# na leitura, nunca gravada; nada do perfil nos logs de parâmetros.
RSpec.describe Citizen, "perfil" do
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "idade no aniversário, na véspera e em 29/02" do
    expect(described_class.age_between(Date.new(1966, 10, 5), Date.new(2026, 10, 5))).to eq(60)
    expect(described_class.age_between(Date.new(1966, 10, 5), Date.new(2026, 10, 4))).to eq(59)
    expect(described_class.age_between(Date.new(2000, 2, 29), Date.new(2026, 2, 28))).to eq(25)
    expect(described_class.age_between(Date.new(2000, 2, 29), Date.new(2026, 3, 1))).to eq(26)
    expect(described_class.age_between(Date.new(2000, 2, 29), Date.new(2028, 2, 29))).to eq(28)
  end

  it "age e profile? leem o perfil; sem perfil, nil e false" do
    expect(citizen.age).to be_nil
    expect(citizen).not_to be_profile
    citizen.update!(birth_date: birth_date_for(62), sex: "female", profile_source: "declared")
    expect(citizen.reload.age).to eq(62)
    expect(citizen).to be_profile
    expect(citizen.profile_context).to eq(age: 62, sex: "female")
    expect(Citizens::ProfileJson.call(citizen))
      .to eq(birth_date: birth_date_for(62), sex: "female", gender_identity: nil, profile_source: "declared")
    expect(Citizens::ProfileJson.call(Citizen.new)).to be_nil
  end

  it "grava birth_date, sex e gender_identity cifrados (não determinístico) e nunca a idade" do
    citizen.update!(birth_date: "1963-04-02", sex: "female", gender_identity: "cis_woman", profile_source: "declared")
    raw = ApplicationRecord.connection.select_one(
      ApplicationRecord.sanitize_sql([ "SELECT birth_date, sex, gender_identity, profile_source FROM citizens WHERE id = ?", citizen.id ])
    )
    expect(raw["birth_date"]).not_to include("1963")
    expect(raw["sex"]).not_to include("female")
    expect(raw["gender_identity"]).not_to include("cis_woman")
    expect(raw["profile_source"]).to eq("declared")
    expect(described_class.column_names).not_to include("age")
    expect(CityEncryption::CITY_KEYED_TARGETS).to include([ Citizen, :birth_date ], [ Citizen, :sex ], [ Citizen, :gender_identity ])
  end

  it "recusa valores fora da lista no modelo" do
    expect(citizen.update(sex: "x", birth_date: "1963-04-02", profile_source: "declared")).to be(false)
    expect(citizen.update(sex: "male", birth_date: "02/04/1963", profile_source: "declared")).to be(false)
    expect(citizen.update(sex: "male", birth_date: "1963-04-02", gender_identity: "y", profile_source: "declared")).to be(false)
    expect(citizen.update(sex: "male", birth_date: "1963-04-02", profile_source: "cadsus")).to be(false)
  end

  it "filtra os três campos do log de parâmetros" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter("birth_date" => "1963-04-02", "sex" => "female", "gender_identity" => "cis_woman"))
      .to eq("birth_date" => "[FILTERED]", "sex" => "[FILTERED]", "gender_identity" => "[FILTERED]")
  end
end
