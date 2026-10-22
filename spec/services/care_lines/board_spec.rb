require "rails_helper"

# Contrato §5 e §11 L6; plano, Desvio 9; Review Focus 3: blocos de `limit`
# avaliados em lote, até 5 blocos com filtro; SQL por bloco constante.
RSpec.describe CareLines::Board do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:team) { care_team!(unit, doctor) }
  let(:line) { adopted_line!("elderly_c6") }
  let(:today) { Time.zone.today }

  # Sem consulta: as práticas rastreadas da C6 ficam vencidas.
  def enroll!(at)
    care_enrollment!(patient: care_patient!(age: 70, sex: "male"), line: line, team: team, by: doctor, enrolled_at: at)
  end

  def queries
    count = 0
    callback = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  it "o número de SQL por bloco não cresce com o tamanho do bloco" do
    6.times { |i| enroll!((i + 1).days.ago) }
    team.reload
    small = queries { described_class.page(team: team, line_id: nil, status: "all", before: nil, limit: 1, today: today) }
    large = queries { described_class.page(team: team, line_id: nil, status: "all", before: nil, limit: 6, today: today) }
    expect(large).to eq(small)
  end

  it "com filtro, varre no máximo 5 blocos e devolve o cursor da última inscrição varrida" do
    enrollments = Array.new(7) { |i| enroll!((i + 1).days.ago) }
    page = described_class.page(team: team, line_id: nil, status: "due_soon", before: nil, limit: 1, today: today)
    expect(page[:rows]).to eq([])
    fifth = enrollments[4]
    expect(CareLines::Cursor.decode(page[:next_before])).to have_attributes(id: fifth.id)
    rest = described_class.page(team: team, line_id: nil, status: "overdue", before: CareLines::Cursor.decode(page[:next_before]), limit: 5,
                                today: today)
    expect(rest[:rows].map { |enrollment, _| enrollment.id }).to eq(enrollments.last(2).map(&:id))
    expect(rest[:next_before]).to be_nil
  end

  it "contador de vencidas em lotes, sem trilha" do
    2.times { |i| enroll!((i + 1).days.ago) }
    expect { expect(described_class.overdue_count(team, today: today)).to eq(2) }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
  end

  describe CareLines::Cursor do
    it "ida e volta com microssegundos; lixo vira Invalid" do
      at = Time.utc(2026, 10, 22, 12, 0, 0, 123_456)
      id = SecureRandom.uuid
      expect(described_class.decode(described_class.encode(at, id))).to have_attributes(at: at, id: id)
      expect(described_class.decode(nil)).to be_nil
      expect(described_class.decode("")).to be_nil
      [ "x", Base64.urlsafe_encode64("2026-10-22|#{id}"), [ "a" ] ].each do |raw|
        expect { described_class.decode(raw) }.to raise_error(CareLines::Cursor::Invalid)
      end
    end
  end
end
