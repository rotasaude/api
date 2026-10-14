require "rails_helper"

# Task 4: days_for recusa etapa desconhecida (Exams::Deadlines alimenta o método).
RSpec.describe "days_for com etapa" do
  before { exam_city! }

  it "aceita as cinco etapas e recusa o resto, no catálogo e no prestador" do
    item = exam_catalog_item!(result_days: 9)
    link = ExamProviderItem.create!(exam_provider: exam_provider!(items: []), exam_catalog_item: item, collect_days: 4)
    expect(item.days_for("result")).to eq(9)
    expect(item.days_for(:result)).to eq(9)
    expect(link.days_for("collect")).to eq(4)
    [ item, link ].each do |record|
      expect { record.days_for("bogus") }.to raise_error(ArgumentError, "unknown stage")
      expect { record.days_for("id") }.to raise_error(ArgumentError, "unknown stage")
      expect { record.days_for(nil) }.to raise_error(ArgumentError, "unknown stage")
    end
  end
end
