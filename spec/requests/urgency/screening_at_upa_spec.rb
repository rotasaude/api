require "rails_helper"

# Módulo 32a (contrato §1 e §14 Q30): a UPA não faz a escuta do 18, e o
# simulador da escuta também não responde nela — nem para o `walk_in` da
# urgência (sem cidadão: antes, 500), nem para um atendimento do 13 na UPA.
RSpec.describe "Sugestão da escuta numa UPA", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }

  before { ciap2_release!; acolhimento! }

  def suggest!(attendance_id)
    json_post "/attendance/screenings/suggest", ciap2_code: "K86", attendance_id: attendance_id,
                                                vitals: { systolic: 185, diastolic: 110 }
  end

  it "walk_in da urgência e atendimento do 13 na UPA → 422 screening_not_in_upa, sem gravar nada" do
    unknown = arrived!(upa, unidentified: "Homem idoso de camisa xadrez")
    attendance = walk_in_attendance!(upa, citizen: screening_citizen!(1))
    sign_in_as(nurse)
    [ unknown.attendance_id, attendance.id ].each do |id|
      suggest!(id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq("error" => "screening_not_in_upa")
    end
    expect(ScreeningRevision.count).to eq(0)
    expect(Screening.count).to eq(0)
  end

  it "fora da UPA a sugestão continua" do
    ubs = create_unit("UBS Centro #{SecureRandom.hex(2)}")
    attendance = walk_in_attendance!(ubs, citizen: screening_citizen!(2))
    sign_in_as(screener!(ubs))
    suggest!(attendance.id)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["suggested_color"]).to eq("red")
  end
end
