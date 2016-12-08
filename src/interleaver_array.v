// Implementing rsweep_chng interleaver
`timescale 1ns/100ps

module interleaver_set #(
	parameter fo = 2,
	parameter fi  = 4,
	parameter p  = 32,
	parameter n  = 8,
	parameter z  = 8,
	parameter [$clog2(p/z)-1:0] sweepstart [0:fo*z-1] = '{2'd1,2'd3,2'd2,2'd0,2'd0,2'd2,2'd1,2'd3,2'd2,2'd0,2'd3,2'd1,2'd3,2'd1,2'd0,2'd2}
	// For every sweep from 0 to fo-1, there is a starting vector which is z elements long, where each element can take values from 0 to p/z-1
	// So total size of sweepstart is fo*z elements of log(p/z) bits each. The whole thing can be psuedo-randomly generated in Python, then passed
)(
	input [$clog2(fo*p/z)-1:0] cycle_index, //log of total number of cycles to process a junction = log(no. of weights / z)
	// [Eg: Here total no. of cycles to process a junction = 8, so cycle_index is 3b. It goes as 000 -> 001 -> ... -> 111]
	output [$clog2(p)*z-1:0] memory_index_package //This has all addresses [Eg: Here this has z=8 5b values, indexing the 8 neurons which need to be accessed out of 32 lefthand neurons]
);

	wire [$clog2(p*fo)-1:0] wt [0:z-1]; //Index of output side weight being read
	//z weights are read in each running of this module, and each has log(p*fo)-bit index since there are (p*fo) weights in total
	wire [$clog2(p/z)-1:0] t [0:p-1]; //t is same as earlier capital S
	wire [$clog2(p)-1:0] memory_index [0:z-1];

	genvar gv_i, gv_j;
	generate //create t
		for (gv_i = 0; gv_i < p/z; gv_i = gv_i+1) begin
			for (gv_j = 0; gv_j<z; gv_j = gv_j + 1) begin
				//For addition, we don't need to put modulo p/z because each element of sweepstart iz p/z bits, so it automatically does modulo
				//[Eg: If p/z=4, then each element of sweepstart is 0 or 1 or 2 or 3. So if we do something like s[6]+3 = 3+3 = 6, it automatically stores 6 as 6%4=2]
				if (fo==1) assign t[gv_i*z+gv_j] = sweepstart[gv_j]+gv_i; //If fo=1, sweepstart just has z elements. Just pick the relevant element 
				else assign t[gv_i*z+gv_j] = sweepstart[gv_j+cycle_index[$clog2(fo*p/z)-1:$clog2(p/z)]*z]+gv_i; /*If fo>1, sweepstart will have fo*z elements
				In this case, we need to shift the index of sweepstart depending on the sweep number
				[Eg: Say p=32, fo=4, z=8 => cycle_index goes from 0000 -> 1111. The 2 MSBs give the sweep number, so we add 2MSBs*z to the index of sweepstart]*/
			end
		end
	endgenerate

	generate //weight interleaver
		for (gv_i = 0; gv_i<z; gv_i = gv_i + 1) begin
			assign wt[gv_i] = cycle_index*z + gv_i;
			assign memory_index[gv_i] = t[wt[gv_i][$clog2(p)-1:0]]*z + wt[gv_i][$clog2(z)-1:0];
		end
	endgenerate

	generate //pack memory_index into package in opposite order
	// i.e. M0 goes to 1st p bits, then M1 and finally Mz-1. This ordering doesn't really matter
		for (gv_i = 0; gv_i<z; gv_i = gv_i + 1) begin
			assign memory_index_package[$clog2(p)*(gv_i+1)-1:$clog2(p)*gv_i] = memory_index[gv_i];
		end
	endgenerate
endmodule


/* Old code for creating s from r:
		if (z >= p/z) begin
			for (gv_i = 0; gv_i < z*z/p; gv_i = gv_i+1) begin
				for (gv_j = 0; gv_j < p/z; gv_j = gv_j+1) begin
					assign s[gv_i*p/z+gv_j] = r[gv_j];
				end
			end
		end else begin // Here z < p/z
			for (gv_i = 0; gv_i<z; gv_i = gv_i + 1) begin
				assign s[gv_i] = r[gv_i];
			end
		end
*/
