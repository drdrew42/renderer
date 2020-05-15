// Development file only.
let user = null;
let key = null;

// get static values from webwork
const courseName = document.getElementById("courseName").value;
const leaderboardURL =
	document.getElementById("site_url").value +
	"/js/apps/Leaderboard/leaderboard-global.php";
const pointsPerProblem = document.getElementById('achievementPPP').value;

// we must pull the user + key to authenticate for php
// php script is set to require a valid user/key pair
function checkCookies() {
	const value = getCookie(`WeBWorKCourseAuthen.${courseName}`); // getCookie defined at the bottom
	user = value.split("\t")[0];
	key = value.split("\t")[1];
}
if (!user & !key) {
	checkCookies();
}

class LeaderTable extends React.Component {
	constructor() {
		super();
		this.state = {
			data: [],
			local: [],
			global: [],
			ourUID: null,
			/* option: null, remove? */
			/* clicks: 0, remove */
			current: null,
			/* currentSort: null, remove */
			view: null,
			placeLocal: null,
			placeGlobal: null,
			place: null
		};
		this.checkOption = this.checkOption.bind(this);
		this.swapLocal = this.swapLocal.bind(this);
	}

	componentDidMount() {

		const requestObject = {
			user,
			key,
			courseName: courseName
		};

		$.post(
			leaderboardURL,
			requestObject,
			data => {
				/* first grab our unique ID - even if we have null achievement points */
				const ourUID = (data.find(item => (item.id == user && item.ours == 1) )||{}).uid || -1;
				/* filter out users with null achievement points */
				var globalData = data.filter( item => item.achievementPoints );
				/* add fields based on their section's number of assigned problems */
				globalData.forEach(item => {
					let maxScore = parseInt(item.numOfProblems)*parseInt(pointsPerProblem)+parseInt(item.achievementPtsSum);
					item.progress = Math.floor((parseInt(item.achievementPoints) / maxScore) * 1000) / 10;
				});
				/* sort the global data then filter down to local */
				globalData.sort( (a, b) => parseFloat(b.progress) - parseFloat(a.progress) );
				var localData = globalData.filter( item => item.ours );
				/* grab the position of our user, -1 if not a student */
				const placeLocal = localData.map(item => item.uid).indexOf(ourUID) +1;
				const placeGlobal = globalData.map(item => item.uid).indexOf(ourUID) +1;
				this.setState({
					data: localData,
					local: localData,
					global: globalData,
					ourUID: ourUID,
					placeLocal: placeLocal,
					placeGlobal: placeGlobal,
					place: placeLocal,
					current: "Progress",
					view: 'Local'
				});
			},
			"json"
		);
	}

	swapLocal() {
		if (this.state.view === 'Local') {
			this.setState({view: 'Global', data: this.state.global, place: this.state.placeGlobal });
		} else {
			this.setState({view: 'Local', data: this.state.local, place: this.state.placeLocal });
		}
	}

	checkOption(option) {
		let newDataGlobal = this.state.global;
		if (option.target.id == "Earned") {
			console.log(`sorting by achievements earned`);
			newDataGlobal.sort( (a, b) => parseFloat(b.achievementsEarned) - parseFloat(a.achievementsEarned) );
		} else if (option.target.id == "Points") {
			console.log(`sorting by number of total points earned`);
			newDataGlobal.sort( (a, b) => parseFloat(b.achievementPoints) - parseFloat(a.achievementPoints) );
		} else if (option.target.id == "Progress") {
			console.log(`sorting by percentage of progress to maxscore`);
			newDataGlobal.sort( (a, b) => parseFloat(b.progress) - parseFloat(a.progress) );
		}
		let newDataLocal = newDataGlobal.filter( item =>item.ours );
		let newData = (this.state.view == 'Local') ? newDataLocal : newDataGlobal;
		const placeLocal = newDataLocal.map(item => item.uid).indexOf(this.state.ourUID) +1;
		const placeGlobal = newDataGlobal.map(item => item.uid).indexOf(this.state.ourUID) +1;
		let newPlace = (this.state.view == 'Local')?placeLocal:placeGlobal;
		this.setState({
			data: newData,
			local: newDataLocal,
			global: newDataGlobal,
			placeLocal: placeLocal,
			placeGlobal: placeGlobal,
			place: newPlace,
			current: option.target.id
		});
	}

	renderBody() {
		let tableInfo = [];
		if (this.state.data.length > 0) {
			for (var i = 0; i < this.state.data.length; i++) {
				let current = this.state.data[i];
				if (tableInfo.length >= 50) {break;}
				let keyHash = current.id.substring(0,4)+current.uid.substring(5);
				let itme = (current.uid === this.state.ourUID);
				tableInfo.push(
					<LeaderTableItem rID={itme} key={keyHash}>
						<td className="tdStyleLB">
							{itme ? "#" + this.state.place + " " : ""}{current.username ? current.username : "Anonymous"}
						</td>
						<td className="tdStyleLB">{current.achievementsEarned}</td>
						<td className="tdStyleLB">
							{current.achievementPoints ? current.achievementPoints : 0}
						</td>
						<td className="tdStyleLB">
							<Filler percentage={current.progress} />
						</td>
					</LeaderTableItem>
				);
			}
		}
		return tableInfo;
	}

	renderFoot() {
		let current = this.state.data.find(item => item.uid == this.state.ourUID)||{};
		let keyHash = current.uid;
		let footer =
					<LeaderTableItem rID={true} key={keyHash}>
						<td className="tdStyleLB">
							{"#" + this.state.place} {current.username ? current.username : "Anonymous"}
						</td>
						<td className="tdStyleLB">{current.achievementsEarned}</td>
						<td className="tdStyleLB">
							{current.achievementPoints ? current.achievementPoints : 0}
						</td>
						<td className="tdStyleLB">
							<Filler	percentage={current.progress} />
						</td>
					</LeaderTableItem>;
		return footer;
	}

	render() {

		let tableBody = this.renderBody();
		let tableFoot = (parseInt(this.state.ourUID) > 0 && this.state.place > 50)?this.renderFoot():"";

		return (
			<div className="lbContainer">
				<table className="lbTable">
				<caption>Sponsored by Santander Bank</caption>
				<thead>
				<tr>
					<th
					colSpan={3}
					id="leaderboardHeading"
					onClick={this.swapLocal}
					>{this.state.view=='Local'?">>>":"<<<"} {this.state.view} Leaderboard {this.state.view=='Local'?"<<<":">>>"}</th>
				</tr>
				<tr>
					<th id="username">Username</th>
					<th
						className="sortButtons"
						id="Earned"
						onClick={this.checkOption}
					>
						Achievements Earned
						{this.state.current == "Earned" ? <i className="ion-android-arrow-dropdown" /> : null}
					</th>
					<th
						className="sortButtons"
						id="Points"
						onClick={this.checkOption}
					>
						Achievement Points
						{this.state.current == "Points" ? <i className="ion-android-arrow-dropdown" /> : null}
					</th>
					<th
						className="sortButtons"
						id="Progress"
						onClick={this.checkOption}
					>
						Achievement Points Collected
						{this.state.current == "Progress" ? <i className="ion-android-arrow-dropdown" /> : null}
					</th>
				</tr>
				</thead>
				<tbody>{tableBody}</tbody>
				<tfoot>{tableFoot}</tfoot>
				</table>
			</div>
		);
	}
}

class LeaderTableItem extends React.Component {
	render() {
		if (this.props.rID) { return <tr className="myRow">{this.props.children}</tr>; }
		return <tr className="LeaderItemTr">{this.props.children}</tr>;
	}
}

class Leaderboard extends React.Component {
	render() {
		return (
			<div>
				<LeaderTable />
			</div>
		);
	}
}

class Filler extends React.Component {

	constructor() {
		super();
		this.state = { color: null };
		this.changeColor = this.changeColor.bind(this);
	}

	changeColor() {
		const perc = parseInt(this.props.percentage);
		var r, g, b = 0;
		if(perc < 50) {
			r = 255;
			g = Math.round(5.1 * perc);
		} else {
			g = 255;
			r = Math.round(510 - 5.10 * perc);
		}
		var h = r * 0x10000 + g * 0x100 + b * 0x1;
		return '#' + ('000000' + h.toString(16)).slice(-6);
	}

	render() {
		return (
			<div className="fillerContainer">
				<span className="fillerBar"
				style={{
					width: `${this.props.percentage}%`,
					background: this.changeColor()
				}}
				></span>
				<div className="fillerLabel"
				style={{
					left: `${this.props.percentage}%`
				}}>
				{this.props.percentage}%
				</div>
			</div>
		);
	}
}

//Utility functions
function formEncode(obj) {
	var str = [];
	for (var p in obj)
		str.push(encodeURIComponent(p) + "=" + encodeURIComponent(obj[p]));
	return str.join("&");
}

function getCookie(cname) {
	const name = cname + "=";
	const decodedCookie = decodeURIComponent(document.cookie);
	const ca = decodedCookie.split(";");
	for (let i = 0; i < ca.length; i++) {
		let c = ca[i];
		while (c.charAt(0) == " ") {
			c = c.substring(1);
		}
		if (c.indexOf(name) == 0) {
			return c.substring(name.length, c.length);
		}
	}
	return "";
}

ReactDOM.render(<Leaderboard />, document.getElementById("LeaderboardPage"));
