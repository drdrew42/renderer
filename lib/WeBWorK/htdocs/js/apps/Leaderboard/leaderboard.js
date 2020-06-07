"use strict";

var _createClass = function () { function defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } } return function (Constructor, protoProps, staticProps) { if (protoProps) defineProperties(Constructor.prototype, protoProps); if (staticProps) defineProperties(Constructor, staticProps); return Constructor; }; }();

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _possibleConstructorReturn(self, call) { if (!self) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return call && (typeof call === "object" || typeof call === "function") ? call : self; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function, not " + typeof superClass); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, enumerable: false, writable: true, configurable: true } }); if (superClass) Object.setPrototypeOf ? Object.setPrototypeOf(subClass, superClass) : subClass.__proto__ = superClass; }

// Development file only.
var user = null;
var key = null;

// get static values from webwork
var courseName = document.getElementById("courseName").value;
var leaderboardURL = document.getElementById("site_url").value + "/js/apps/Leaderboard/leaderboard-global.php";
var pointsPerProblem = document.getElementById('achievementPPP').value;

// we must pull the user + key to authenticate for php
// php script is set to require a valid user/key pair
function checkCookies() {
	var value = getCookie("WeBWorKCourseAuthen." + courseName); // getCookie defined at the bottom
	user = value.split("\t")[0];
	key = value.split("\t")[1];
}
if (!user & !key) {
	checkCookies();
}

var LeaderTable = function (_React$Component) {
	_inherits(LeaderTable, _React$Component);

	function LeaderTable() {
		_classCallCheck(this, LeaderTable);

		var _this = _possibleConstructorReturn(this, (LeaderTable.__proto__ || Object.getPrototypeOf(LeaderTable)).call(this));

		_this.state = {
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
		_this.checkOption = _this.checkOption.bind(_this);
		_this.swapLocal = _this.swapLocal.bind(_this);
		return _this;
	}

	_createClass(LeaderTable, [{
		key: "componentDidMount",
		value: function componentDidMount() {
			var _this2 = this;

			var requestObject = {
				user: user,
				key: key,
				courseName: courseName
			};

			$.post(leaderboardURL, requestObject, function (data) {
				/* first grab our unique ID - even if we have null achievement points */
				var ourUID = (data.find(function (item) {
					return item.id == user && item.ours == 1;
				}) || {}).uid || -1;
				/* filter out users with null achievement points */
				var globalData = data.filter(function (item) {
					return item.achievementPoints;
				});
				/* add fields based on their section's number of assigned problems */
				globalData.forEach(function (item) {
					var maxScore = parseInt(item.numOfProblems) * parseInt(pointsPerProblem) + parseInt(item.achievementPtsSum);
					item.progress = Math.floor(parseInt(item.achievementPoints) / maxScore * 1000) / 10;
				});
				/* sort the global data then filter down to local */
				globalData.sort(function (a, b) {
					return parseFloat(b.progress) - parseFloat(a.progress);
				});
				var localData = globalData.filter(function (item) {
					return item.ours;
				});
				/* grab the position of our user, -1 if not a student */
				var placeLocal = localData.map(function (item) {
					return item.uid;
				}).indexOf(ourUID) + 1;
				var placeGlobal = globalData.map(function (item) {
					return item.uid;
				}).indexOf(ourUID) + 1;
				_this2.setState({
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
			}, "json");
		}
	}, {
		key: "swapLocal",
		value: function swapLocal() {
			if (this.state.view === 'Local') {
				this.setState({ view: 'Global', data: this.state.global, place: this.state.placeGlobal });
			} else {
				this.setState({ view: 'Local', data: this.state.local, place: this.state.placeLocal });
			}
		}
	}, {
		key: "checkOption",
		value: function checkOption(option) {
			var newDataGlobal = this.state.global;
			if (option.target.id == "Earned") {
				console.log("sorting by achievements earned");
				newDataGlobal.sort(function (a, b) {
					return parseFloat(b.achievementsEarned) - parseFloat(a.achievementsEarned);
				});
			} else if (option.target.id == "Points") {
				console.log("sorting by number of total points earned");
				newDataGlobal.sort(function (a, b) {
					return parseFloat(b.achievementPoints) - parseFloat(a.achievementPoints);
				});
			} else if (option.target.id == "Progress") {
				console.log("sorting by percentage of progress to maxscore");
				newDataGlobal.sort(function (a, b) {
					return parseFloat(b.progress) - parseFloat(a.progress);
				});
			}
			var newDataLocal = newDataGlobal.filter(function (item) {
				return item.ours;
			});
			var newData = this.state.view == 'Local' ? newDataLocal : newDataGlobal;
			var placeLocal = newDataLocal.map(function (item) {
				return item.uid;
			}).indexOf(this.state.ourUID) + 1;
			var placeGlobal = newDataGlobal.map(function (item) {
				return item.uid;
			}).indexOf(this.state.ourUID) + 1;
			var newPlace = this.state.view == 'Local' ? placeLocal : placeGlobal;
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
	}, {
		key: "renderBody",
		value: function renderBody() {
			var tableInfo = [];
			if (this.state.data.length > 0) {
				for (var i = 0; i < this.state.data.length; i++) {
					var current = this.state.data[i];
					if (tableInfo.length >= 50) {
						break;
					}
					var keyHash = current.id.substring(0, 4) + current.uid.substring(5);
					var itme = current.uid === this.state.ourUID;
					tableInfo.push(React.createElement(
						LeaderTableItem,
						{ rID: itme, key: keyHash },
						React.createElement(
							"td",
							{ className: "tdStyleLB" },
							itme ? "#" + this.state.place + " " : "",
							current.username ? current.username : "Anonymous"
						),
						React.createElement(
							"td",
							{ className: "tdStyleLB" },
							current.achievementsEarned
						),
						React.createElement(
							"td",
							{ className: "tdStyleLB" },
							current.achievementPoints ? current.achievementPoints : 0
						),
						React.createElement(
							"td",
							{ className: "tdStyleLB" },
							React.createElement(Filler, {
								percentage: current.progress
							})
						)
					));
				}
			}
			return tableInfo;
		}
	}, {
		key: "renderFoot",
		value: function renderFoot() {
			var _this3 = this;

			var current = this.state.data.find(function (item) {
				return item.uid == _this3.state.ourUID;
			}) || {};
			var keyHash = current.uid;
			var footer = React.createElement(
				LeaderTableItem,
				{ rID: true, key: keyHash },
				React.createElement(
					"td",
					{ className: "tdStyleLB" },
					"#" + this.state.place,
					" ",
					current.username ? current.username : "Anonymous"
				),
				React.createElement(
					"td",
					{ className: "tdStyleLB" },
					current.achievementsEarned
				),
				React.createElement(
					"td",
					{ className: "tdStyleLB" },
					current.achievementPoints ? current.achievementPoints : 0
				),
				React.createElement(
					"td",
					{ className: "tdStyleLB" },
					React.createElement(Filler, {
						percentage: current.progress
					})
				)
			);
			return footer;
		}
	}, {
		key: "render",
		value: function render() {

			var tableBody = this.renderBody();
			var tableFoot = parseInt(this.state.ourUID) > 0 && this.state.place > 50 ? this.renderFoot() : "";

			return React.createElement(
				"div",
				{ className: "lbContainer" },
				React.createElement(
					"table",
					{ className: "lbTable" },
					React.createElement(
						"caption",
						null,
						"Sponsored by Santander Bank"
					),
					React.createElement(
						"thead",
						null,
						React.createElement(
							"tr",
							null,
							React.createElement(
								"th",
								{
									colSpan: 3,
									id: "leaderboardHeading",
									onClick: this.swapLocal
								},
								this.state.view == 'Local' ? ">>>" : "<<<",
								" ",
								this.state.view,
								" Leaderboard ",
								this.state.view == 'Local' ? "<<<" : ">>>"
							)
						),
						React.createElement(
							"tr",
							null,
							React.createElement(
								"th",
								{ id: "username" },
								"Username"
							),
							React.createElement(
								"th",
								{
									className: "sortButtons",
									id: "Earned",
									onClick: this.checkOption
								},
								"Achievements Earned",
								this.state.current == "Earned" ? React.createElement("i", { className: "ion-android-arrow-dropdown" }) : null
							),
							React.createElement(
								"th",
								{
									className: "sortButtons",
									id: "Points",
									onClick: this.checkOption
								},
								"Achievement Points",
								this.state.current == "Points" ? React.createElement("i", { className: "ion-android-arrow-dropdown" }) : null
							),
							React.createElement(
								"th",
								{
									className: "sortButtons",
									id: "Progress",
									onClick: this.checkOption
								},
								"Achievement Points Collected",
								this.state.current == "Progress" ? React.createElement("i", { className: "ion-android-arrow-dropdown" }) : null
							)
						)
					),
					React.createElement(
						"tbody",
						null,
						tableBody
					),
					React.createElement(
						"tfoot",
						null,
						tableFoot
					)
				)
			);
		}
	}]);

	return LeaderTable;
}(React.Component);

var LeaderTableItem = function (_React$Component2) {
	_inherits(LeaderTableItem, _React$Component2);

	function LeaderTableItem() {
		_classCallCheck(this, LeaderTableItem);

		return _possibleConstructorReturn(this, (LeaderTableItem.__proto__ || Object.getPrototypeOf(LeaderTableItem)).apply(this, arguments));
	}

	_createClass(LeaderTableItem, [{
		key: "render",
		value: function render() {
			if (this.props.rID) {
				return React.createElement(
					"tr",
					{ className: "myRow" },
					this.props.children
				);
			}
			return React.createElement(
				"tr",
				{ className: "LeaderItemTr" },
				this.props.children
			);
		}
	}]);

	return LeaderTableItem;
}(React.Component);

var Leaderboard = function (_React$Component3) {
	_inherits(Leaderboard, _React$Component3);

	function Leaderboard() {
		_classCallCheck(this, Leaderboard);

		return _possibleConstructorReturn(this, (Leaderboard.__proto__ || Object.getPrototypeOf(Leaderboard)).apply(this, arguments));
	}

	_createClass(Leaderboard, [{
		key: "render",
		value: function render() {
			return React.createElement(
				"div",
				null,
				React.createElement(LeaderTable, null)
			);
		}
	}]);

	return Leaderboard;
}(React.Component);

var Filler = function (_React$Component4) {
	_inherits(Filler, _React$Component4);

	function Filler() {
		_classCallCheck(this, Filler);

		var _this6 = _possibleConstructorReturn(this, (Filler.__proto__ || Object.getPrototypeOf(Filler)).call(this));

		_this6.state = { color: null };
		_this6.changeColor = _this6.changeColor.bind(_this6);
		return _this6;
	}

	_createClass(Filler, [{
		key: "changeColor",
		value: function changeColor() {
			var perc = parseInt(this.props.percentage);
			var r,
			    g,
			    b = 0;
			if (perc < 50) {
				r = 255;
				g = Math.round(5.1 * perc);
			} else {
				g = 255;
				r = Math.round(510 - 5.10 * perc);
			}
			var h = r * 0x10000 + g * 0x100 + b * 0x1;
			return '#' + ('000000' + h.toString(16)).slice(-6);
		}
	}, {
		key: "render",
		value: function render() {
			return React.createElement(
				"div",
				{ className: "fillerContainer" },
				React.createElement("span", { className: "fillerBar",
					style: {
						width: this.props.percentage + "%",
						background: this.changeColor()
					}
				}),
				React.createElement(
					"div",
					{ className: "fillerLabel",
						style: {
							left: this.props.percentage + "%"
						} },
					this.props.percentage,
					"%"
				)
			);
		}
	}]);

	return Filler;
}(React.Component);

//Utility functions


function formEncode(obj) {
	var str = [];
	for (var p in obj) {
		str.push(encodeURIComponent(p) + "=" + encodeURIComponent(obj[p]));
	}return str.join("&");
}

function getCookie(cname) {
	var name = cname + "=";
	var decodedCookie = decodeURIComponent(document.cookie);
	var ca = decodedCookie.split(";");
	for (var i = 0; i < ca.length; i++) {
		var c = ca[i];
		while (c.charAt(0) == " ") {
			c = c.substring(1);
		}
		if (c.indexOf(name) == 0) {
			return c.substring(name.length, c.length);
		}
	}
	return "";
}

ReactDOM.render(React.createElement(Leaderboard, null), document.getElementById("LeaderboardPage"));
