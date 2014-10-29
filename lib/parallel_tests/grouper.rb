require 'Genmodel'

module ParallelTests
  class Grouper
    class << self
      def by_steps(tests, num_groups, options)
        features_with_steps = build_features_with_steps(tests, options)
        in_even_groups_by_size(features_with_steps, num_groups)
      end

      def by_scenarios(tests, num_groups, options={})
        scenarios = group_by_scenarios(tests, options)
        in_even_groups_by_size(scenarios, num_groups)
      end

      def in_even_groups_by_size(items, num_groups, options= {})
        groups = Array.new(num_groups) { {:items => [], :size => 0} }

        # add all files that should run in a single process to one group
        (options[:single_process] || []).each do |pattern|
          matched, items = items.partition { |item, size| item =~ pattern }
          matched.each { |item, size| add_to_group(groups.first, item, size) }
        end

        groups_to_fill = (options[:isolate] ? groups[1..-1] : groups)
        group_features_by_size(items_to_group(items), groups_to_fill)

        groups.map!{|g| g[:items].sort }
      end

      private

      def largest_first(files)
        files.sort_by{|item, size| size }.reverse
      end

      def smallest_group(groups)
        groups.min_by{|g| g[:size] }
      end

      def add_to_group(group, item, size)
        group[:items] << item
        group[:size] += size
      end

      def build_features_with_steps(tests, options)
        require 'parallel_tests/gherkin/listener'
        listener = ParallelTests::Gherkin::Listener.new
        listener.ignore_tag_pattern = Regexp.compile(options[:ignore_tag_pattern]) if options[:ignore_tag_pattern]
        parser = ::Gherkin::Parser::Parser.new(listener, true, 'root')
        tests.each{|file|
          parser.parse(File.read(file), file, 0)
        }
        listener.collect.sort_by{|_,value| -value }
      end

      def group_by_scenarios(tests, options={})
        require 'parallel_tests/cucumber/scenarios'
        ParallelTests::Cucumber::Scenarios.all(tests, options)
      end

      def group_features_by_size_best_effort(items, groups_to_fill)
        items.each do |item, size|
          size ||= 1
          smallest = smallest_group(groups_to_fill)
          add_to_group(smallest, item, size)
        end
      end

      def group_features_by_size_solver(solver, items, groups_to_fill)
        solver.SetBoolParam("mip", true)
        solver.SetBoolParam("maximize", false)
        #solver.SetBoolParam('log_output_stdout', true)
        solver.SetDblParam('relative_mip_gap_tolerance', 0.002)

        # Add variables
        m = groups_to_fill.size
        n = items.size
        n.times { |i| m.times { |j| solver.AddVar("x_assign_test#{i}_to_bucket#{j}", 0.0, 0.0, 1.0, 'B') } }
        solver.AddVar("y_max_time", 1.0, 0.0, Float::INFINITY, 'C')

        # Add constraints
        n.times do |i|
          solver.AddConst("assign_test#{i}_to_one_bucket", 1.0, 'E')
          m.times { |j| solver.AddNzToLast(i*m+j, 1.0) }
        end

        m.times do |j|
          solver.AddConst("total_time_of_bucket#{j}_less_than_max_time", 0.0, 'L')
          items.each_with_index  {|(_, size), index| solver.AddNzToLast(index*m+j, size)}
          solver.AddNzToLast(n*m, -1.0)
        end

        solver.SetNumbers
        solver.Init("JenkinsAssign")
        solver.CreateModel

        solver.Solve
        solver.SetSol

        if solver.hassolution
          solution = solver.vars.GetSolution
          items.each_with_index do |(path, size), i|
            groups_to_fill.each_with_index do |group, j|
              add_to_group(group, path, size) if solution[i*m+j] > 0.99
            end
          end
          groups_to_fill.each_with_index do |group, index|
            puts "group_features_by_size_solver: total_time for bucket #{index + 1}: #{group[:size]}s"
          end
        else
          abort "group_features_by_size_solver: No solution found"
        end
      end

      def group_features_by_size(items, groups_to_fill)
        solver = if Genmodel::GenModelCplex.IsAvailable
                   puts "group_features_by_size using Cplex"
                   Genmodel::GenModelCplex.new
                 elsif Genmodel::GenModelOsi.IsAvailable
                   puts "group_features_by_size using Coin-OR"
                   Genmodel::GenModelOsi.new
                 else
                   false
                 end
        if solver
          group_features_by_size_solver(solver, items, groups_to_fill)
        else
          puts "group_features_by_size using best effort"
          group_features_by_size_best_effort(items, groups_to_fill)
        end
      end

      def items_to_group(items)
        items.first && items.first.size == 2 ? largest_first(items) : items
      end
    end
  end
end
