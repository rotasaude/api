FactoryBot.define do
  factory :municipality do
    sequence(:name)      { |n| "Cidade #{n}" }
    sequence(:slug)      { |n| "cidade-#{n}" }
    sequence(:ibge_code) { |n| "350#{n.to_s.rjust(4, '0')}" }
  end
end
