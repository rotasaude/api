require "rails_helper"

# Contrato §6; spec §7: o admin municipal vê o saldo de cada prescritor (CRM
# e CRO) no modo corrente e quem está com saldo baixo; só leitura; nada de
# número SNCR, CPF ou inscrição.
RSpec.describe "Painel do SNCR do admin", type: :request do
  before { controlled_city!(mock: true) }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:dentist) { dentist!(unit) }
  def body = JSON.parse(response.body)

  it "saldo por prescritor, baixo, último pedido; sem enfermeiro; sem número" do
    sncr_stock!(doctor, kind: "rce", count: 60)
    sncr_stock!(doctor, kind: "ret", count: 60)
    sncr_stock!(dentist, kind: "rce", count: 10)
    sncr_stock!(doctor, kind: "rce", count: 5, simulated: false)
    nurse!(unit)
    sign_in_as(municipal_admin!)
    get "/sncr/admin/overview"
    expect(response).to have_http_status(:ok)
    rows = body["professionals"].index_by { |row| row["user_id"] }
    expect(rows.keys).to contain_exactly(doctor.id, dentist.id)
    expect(rows[doctor.id]).to include("rce_free" => 60, "ret_free" => 60, "low" => false, "last_request_at" => be_present)
    expect(rows[dentist.id]).to include("rce_free" => 10, "ret_free" => 0, "low" => true)
    expect(body["simulated"]).to be(true)
    expect(response.body).not_to include("2610.", doctor.professional.registration_number)
  end

  it "lote só do outro modo dá last_request_at nil; usuário desativado fica fora" do
    sncr_stock!(doctor, kind: "rce", count: 3, simulated: false)
    gone = dentist!(unit)
    sncr_stock!(gone, kind: "rce", count: 3)
    gone.update_columns(deactivated_at: Time.current)
    sign_in_as(municipal_admin!)
    get "/sncr/admin/overview"
    rows = body["professionals"].index_by { |row| row["user_id"] }
    expect(rows.keys).to eq([ doctor.id ])
    expect(rows[doctor.id]).to include("rce_free" => 0, "last_request_at" => nil)
  end

  it "profissional não vê; interruptor desligado recusa" do
    sign_in_as(doctor)
    get "/sncr/admin/overview"
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(municipal_admin!)
    get "/sncr/admin/overview"
    expect([ response.status, body["feature"] ]).to eq([ 403, "controlled_prescriptions" ])
  end
end
