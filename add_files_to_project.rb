require 'xcodeproj'

project_path = 'AudiobookPlayer.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target_name = 'AudiobookPlayer'
target = project.targets.find { |t| t.name == target_name }

if target
  group_name = 'AudiobookPlayer'
  group = project.main_group.find_sub_group(group_name)
  
  if group
    files_to_add = [
      'ThemeManager.swift',
      'ThemeSelectionView.swift'
    ]
    
    files_to_add.each do |file_name|
      # Check if file is already in the group to avoid duplicates
      # Note: find_file_by_path looks relative to the group
      unless group.find_file_by_path(file_name)
        file_ref = group.new_file(file_name)
        target.add_file_references([file_ref])
        puts "Added #{file_name} to project."
      else
        puts "#{file_name} already exists in project."
      end
    end
    
    project.save
    puts "Project saved."
  else
    puts "Group #{group_name} not found."
  end
else
  puts "Target #{target_name} not found."
end
