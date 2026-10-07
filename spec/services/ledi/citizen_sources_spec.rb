require "rails_helper"

# api#43 (spec §6): a exclusão confirmada apaga payload e códigos das linhas
# da fila cujas fontes são do cidadão. Aceita não muda (já sem conteúdo).
RSpec.describe Ledi::CitizenSources do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }

  def screening_for(citizen)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    link = nurse.professional.links.active.sole
    Screening.create!(attendance: attendance, status: "in_progress", started_by_user: nurse, professional_link: link,
                      cbo_code: link.cbo_code, started_at: Time.current)
  end

  def entry!(source_id, status, ficha_type: "procedimento")
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: ficha_type, competence: "202610",
              source_type: "Screening", source_id: source_id, ledi_version: "8.7.0", status: status,
              next_attempt_at: Time.current, bytes: "x".b }
    attrs[:last_error_codes] = [ { "field" => "cnes", "code" => "invalid" } ] if status == "rejected"
    LediOutboxEntry.create!(attrs)
  end

  it "limpa as linhas do par (pendente vira failed) e não toca as dos outros" do
    mine = screening_for(screening_citizen!(1))
    theirs = screening_for(screening_citizen!(2))
    rejected = entry!(mine.id, "rejected")
    pending = entry!(mine.id, "pending", ficha_type: "atendimento_individual")
    other = entry!(theirs.id, "rejected")

    expect(described_class.scrub!([ mine.attendance.citizen_id ])).to eq(2)
    expect(rejected.reload.slice(:payload, :last_error_codes, :status))
      .to eq("payload" => nil, "last_error_codes" => [], "status" => "rejected")
    expect(pending.reload.slice(:payload, :status)).to eq("payload" => nil, "status" => "failed")
    expect(other.reload.payload).to be_present
  end

  it "trata a linha em envio (sending) como pendente: vira failed e sem conteúdo" do
    mine = screening_for(screening_citizen!(1))
    sending = entry!(mine.id, "sending")

    expect(described_class.scrub!([ mine.attendance.citizen_id ])).to eq(1)
    expect(sending.reload.slice(:payload, :status)).to eq("payload" => nil, "status" => "failed")
  end
end
